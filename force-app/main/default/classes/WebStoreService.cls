/**
 * Core logic for the public web store (nutty-nirvana website).
 * Called by WebStoreAPI (REST) — kept separate so it is unit-testable
 * without RestContext plumbing.
 *
 * Runs without sharing: the integration user only ever enters through
 * the Connected App and this service defines exactly what it can touch.
 */
public without sharing class WebStoreService {

    // Statuses that reserve stock from the website's point of view.
    // Includes Pending Approval so two web buyers can't both claim the
    // last bag while an order is waiting for review.
    private static final Set<String> BLOCKING_STATUSES = new Set<String>{
        'Pending Approval', 'Confirmed', 'Out for Delivery'
    };

    public class WebStoreException extends Exception {}

    // ── Inputs / outputs ──────────────────────────────────────────────────
    public class OrderItemInput {
        public String  slug;
        public Integer packets;
    }
    public class OrderInput {
        public String businessCode;   // existing client's login code
        public String phone;          // any format; normalized to 10 digits
        public String name;           // contact person
        public String businessName;   // shop / business (optional)
        public String address;        // delivery address
        public String gstin;          // optional
        public String note;           // optional customer note
        public String orderRef;       // idempotency key from the website
        public List<OrderItemInput> items;
    }
    public class OrderResult {
        public String  saleId;
        public String  saleName;
        public String  accountId;
        public String  accountName;
        public Boolean newCustomer;
        public String  status;        // Pending Approval | Confirmed
        public Decimal total;
        public Boolean duplicate;     // true when orderRef already processed
    }

    // ── Phone normalization — mirror of WhatsAppHelper.fmtPhone ──────────
    /**
     * Build the client's website login code: first 3 letters of the account
     * name plus the first 5 digits of the phone. Priyanka / 9836482398
     * becomes PRI98364.
     *
     * Callers must guarantee uniqueness — see assignBusinessCodes, which
     * adds a numeric suffix rather than letting a duplicate block the
     * insert. The code is generated once and never recalculated, because a
     * renamed account would otherwise invalidate a code the client already
     * has in their welcome message.
     */
    public static String buildBusinessCode(String accountName, String phone) {
        String letters = accountName == null
            ? '' : accountName.replaceAll('[^A-Za-z]', '').toUpperCase();
        String digits = normalizePhone(phone);
        if (String.isBlank(letters) || String.isBlank(digits)) return null;
        // Short names are padded so the code keeps a predictable shape.
        while (letters.length() < 3) letters += 'X';
        return letters.substring(0, 3) + digits.substring(0, 5);
    }

    /**
     * Stamp codes onto accounts that do not have one yet, resolving clashes
     * against both the org and the rest of this batch.
     *
     * A duplicate would throw DUPLICATE_VALUE and block the account insert
     * outright, so collisions must resolve to a suffix, never to an error.
     */
    public static void assignBusinessCodes(List<Account> accounts) {
        List<Account> needing = new List<Account>();
        for (Account a : accounts) {
            if (String.isBlank(a.Unique_Business_Code__c)
                && buildBusinessCode(a.Name, a.Phone) != null) {
                needing.add(a);
            }
        }
        if (needing.isEmpty()) return;

        // Precompute every code a base could resolve to (base, base2 … base9)
        // so one query covers the whole family. SOQL cannot express
        // "starts with any of these", and this is bounded and exact.
        Set<String> lookFor = new Set<String>();
        for (Account a : needing) {
            String base = buildBusinessCode(a.Name, a.Phone);
            lookFor.add(base);
            for (Integer n = 2; n <= 9; n++) lookFor.add(base + String.valueOf(n));
        }

        Set<String> taken = new Set<String>();
        for (Account a : [
            SELECT Unique_Business_Code__c FROM Account
            WHERE Unique_Business_Code__c IN :lookFor
        ]) {
            if (a.Unique_Business_Code__c != null) {
                taken.add(a.Unique_Business_Code__c.toUpperCase());
            }
        }

        for (Account a : needing) {
            String base = buildBusinessCode(a.Name, a.Phone);
            String code = base;
            Integer n = 1;
            // Past base9 fall back to a random tail rather than looping on a
            // pattern the query above did not cover.
            while (taken.contains(code.toUpperCase())) {
                n++;
                code = n <= 9
                    ? base + String.valueOf(n)
                    : base + String.valueOf(
                        Math.mod(Math.abs(Crypto.getRandomInteger()), 900) + 100);
            }
            taken.add(code.toUpperCase());
            a.Unique_Business_Code__c = code;
        }
    }

    /** Look up a client by their website login code. */
    public static Account findClientByCode(String code) {
        if (String.isBlank(code)) return null;
        String clean = code.trim().toUpperCase();
        List<Account> rows = [
            SELECT Id, Name, Phone, Phone_Digits__c, Unique_Business_Code__c,
                   BillingStreet, BillingCity, BillingState, BillingPostalCode,
                   GSTIN__c
            FROM Account
            WHERE Unique_Business_Code__c = :clean
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    public static String normalizePhone(String raw) {
        if (String.isBlank(raw)) return null;
        String d = raw.replaceAll('[^0-9]', '');
        if (d.length() > 10) d = d.substring(d.length() - 10);
        return d.length() == 10 ? d : null;
    }

    // ── Catalog: active products + live availability ─────────────────────
    public static List<Map<String, Object>> getCatalog() {
        Map<String, Decimal> availableKg = availableByKey();

        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Web_Product__c p : [
            SELECT Id, Name, Slug__c, Brand__c, Packet_Type__c, Grade__c,
                   Description__c, Pack_Size_Grams__c, Price_Per_Kg__c,
                   Price_Per_Packet__c, Pack_Label__c, Min_Order_Packets__c,
                   Badge__c, GST_Applied__c, Sort_Order__c
            FROM Web_Product__c
            WHERE Is_Active__c = true
            ORDER BY Sort_Order__c NULLS LAST, Name
        ]) {
            String key = p.Brand__c + '|' + p.Packet_Type__c;
            Decimal kg = availableKg.containsKey(key)
                         ? availableKg.get(key) : 0;
            Decimal packSizeKg = p.Pack_Size_Grams__c / 1000;
            Integer availablePackets = packSizeKg > 0
                ? (Integer) (kg / packSizeKg).setScale(0, RoundingMode.FLOOR)
                : 0;
            out.add(new Map<String, Object>{
                'slug'             => p.Slug__c,
                'name'             => p.Name,
                'brand'            => p.Brand__c,
                'packetType'       => p.Packet_Type__c,
                'grade'            => p.Grade__c,
                'description'      => p.Description__c,
                'packSizeGrams'    => p.Pack_Size_Grams__c,
                'packLabel'        => p.Pack_Label__c,
                'pricePerKg'       => p.Price_Per_Kg__c,
                'pricePerPacket'   => p.Price_Per_Packet__c,
                'minOrderPackets'  => p.Min_Order_Packets__c != null
                                      ? p.Min_Order_Packets__c : 1,
                'badge'            => p.Badge__c,
                'gstApplied'       => p.GST_Applied__c,
                'availableKg'      => kg.setScale(2),
                'availablePackets' => availablePackets,
                'inStock'          => availablePackets > 0
            });
        }
        return out;
    }

    // ── Place order ──────────────────────────────────────────────────────
    public static OrderResult placeOrder(OrderInput input) {
        if (input == null || input.items == null || input.items.isEmpty())
            throw new WebStoreException('Order has no items.');

        // Two ways in: an existing client's business code, or first-time
        // details. The code is authoritative — when it is present the phone
        // and name come from the matched account, not from the browser.
        Account coded = String.isNotBlank(input.businessCode)
            ? findClientByCode(input.businessCode) : null;
        if (String.isNotBlank(input.businessCode) && coded == null)
            throw new WebStoreException(
                'That business code was not recognised. Check it against your ' +
                'welcome message, or order as a first-time customer.');

        String digits = coded != null
            ? coded.Phone_Digits__c : normalizePhone(input.phone);
        if (digits == null)
            throw new WebStoreException('A valid 10-digit phone number is required.');
        if (coded == null && String.isBlank(input.name))
            throw new WebStoreException('Customer name is required.');

        // Idempotency: same orderRef → return the existing sale
        if (String.isNotBlank(input.orderRef)) {
            List<Sale__c> existing = [
                SELECT Id, Name, Order_Status__c, Total_Revenue__c,
                       Client__c, Client__r.Name
                FROM Sale__c WHERE Web_Order_Ref__c = :input.orderRef
                LIMIT 1
            ];
            if (!existing.isEmpty()) {
                OrderResult dup = new OrderResult();
                dup.saleId      = existing[0].Id;
                dup.saleName    = existing[0].Name;
                dup.accountId   = existing[0].Client__c;
                dup.accountName = existing[0].Client__r?.Name;
                dup.status      = existing[0].Order_Status__c;
                dup.total       = existing[0].Total_Revenue__c;
                dup.newCustomer = false;
                dup.duplicate   = true;
                return dup;
            }
        }

        // Load products for the requested slugs
        Set<String> slugs = new Set<String>();
        for (OrderItemInput it : input.items) {
            if (it == null || String.isBlank(it.slug)
                || it.packets == null || it.packets <= 0)
                throw new WebStoreException('Each item needs a product and a quantity.');
            slugs.add(it.slug);
        }
        Map<String, Web_Product__c> productBySlug = new Map<String, Web_Product__c>();
        for (Web_Product__c p : [
            SELECT Id, Name, Slug__c, Brand__c, Packet_Type__c,
                   Pack_Size_Grams__c, Price_Per_Kg__c,
                   Min_Order_Packets__c, GST_Applied__c
            FROM Web_Product__c
            WHERE Slug__c IN :slugs AND Is_Active__c = true
        ]) productBySlug.put(p.Slug__c, p);

        // Validate items + availability before any DML
        Map<String, Decimal> availableKg = availableByKey();
        Map<String, Decimal> requestedKg = new Map<String, Decimal>();
        for (OrderItemInput it : input.items) {
            Web_Product__c p = productBySlug.get(it.slug);
            if (p == null)
                throw new WebStoreException(
                    'Product "' + it.slug + '" is not available right now.');
            Decimal minPk = p.Min_Order_Packets__c != null
                            ? p.Min_Order_Packets__c : 1;
            if (it.packets < minPk)
                throw new WebStoreException(
                    p.Name + ': minimum order is ' + minPk.setScale(0) + ' pack(s).');

            String key = p.Brand__c + '|' + p.Packet_Type__c;
            Decimal kg = it.packets * p.Pack_Size_Grams__c / 1000;
            requestedKg.put(key,
                (requestedKg.containsKey(key) ? requestedKg.get(key) : 0) + kg);
        }
        for (String key : requestedKg.keySet()) {
            Decimal have = availableKg.containsKey(key) ? availableKg.get(key) : 0;
            if (requestedKg.get(key) > have) {
                String brand = key.substringBefore('|');
                throw new WebStoreException(
                    'Not enough stock for ' + brand + '. Available: ' +
                    have.setScale(2) + ' KG, requested: ' +
                    requestedKg.get(key).setScale(2) + ' KG.');
            }
        }

        // A verified code wins; otherwise fall back to matching on phone so a
        // returning buyer who lost their code is not duplicated.
        Account client = coded != null ? coded : findClientByPhone(digits);
        Boolean isNew  = (client == null);

        Savepoint sp = Database.setSavepoint();
        try {
            if (isNew) {
                Id clientRT = clientRecordTypeId();
                client = new Account(
                    Name             = String.isNotBlank(input.businessName)
                                       ? input.businessName.trim()
                                       : input.name.trim(),
                    Contact_Person__c = left(input.name, 50),
                    Phone            = '+91' + digits,
                    Phone_Digits__c  = digits,
                    AccountSource    = 'Web',
                    ShippingStreet   = left(input.address, 255),
                    GSTIN__c         = left(input.gstin, 15),
                    First_Date_Visited__c = Date.today()
                );
                if (clientRT != null) client.RecordTypeId = clientRT;
                insert client;   // AccountTrigger sends the WhatsApp welcome
            }

            // Every website order waits for approval. The business code is
            // derivable from a client's name and phone, so it identifies a
            // customer but does not authenticate them — a human check stands
            // between a guessed code and a live order in the books.
            String status = 'Pending Approval';

            Sale__c sale = new Sale__c(
                Client__c          = client.Id,
                Sale_Date__c       = Date.today(),
                Order_Status__c    = status,
                Order_Source__c    = 'Website',
                Web_Order_Ref__c   = left(input.orderRef, 64),
                Delivery_Address__c = left(input.address, 1000),
                Notes_Remarks__c   = left(input.note, 255)
            );
            insert sale;

            List<Sale_Line_Item__c> lines = new List<Sale_Line_Item__c>();
            Decimal total = 0;
            for (OrderItemInput it : input.items) {
                Web_Product__c p = productBySlug.get(it.slug);
                Decimal qtyKg = (it.packets * p.Pack_Size_Grams__c / 1000)
                                .setScale(3);
                total += qtyKg * p.Price_Per_Kg__c;
                lines.add(new Sale_Line_Item__c(
                    Sale__c         = sale.Id,
                    Brand__c        = p.Brand__c,
                    Packet_Type__c  = p.Packet_Type__c,
                    Quantity__c     = qtyKg,
                    Rate_Per_Kg__c  = p.Price_Per_Kg__c,
                    GST_Applied__c  = p.GST_Applied__c
                ));
            }
            insert lines;   // trigger validates stock + fires WhatsApp/alerts

            Sale__c saved = [
                SELECT Id, Name FROM Sale__c WHERE Id = :sale.Id LIMIT 1
            ];

            OrderResult res = new OrderResult();
            res.saleId      = saved.Id;
            res.saleName    = saved.Name;
            res.accountId   = client.Id;
            res.accountName = client.Name;
            res.newCustomer = isNew;
            res.status      = status;
            res.total       = total.setScale(2);
            res.duplicate   = false;
            return res;

        } catch (WebStoreException e) {
            Database.rollback(sp);
            throw e;
        } catch (DmlException e) {
            Database.rollback(sp);
            throw new WebStoreException(e.getDmlMessage(0));
        } catch (Exception e) {
            Database.rollback(sp);
            throw new WebStoreException(e.getMessage());
        }
    }

    // ── Order history for a verified phone ───────────────────────────────
    public static List<Map<String, Object>> getOrders(String phone) {
        String digits = normalizePhone(phone);
        if (digits == null) return new List<Map<String, Object>>();
        Account client = findClientByPhone(digits);
        if (client == null) return new List<Map<String, Object>>();

        List<Map<String, Object>> out = new List<Map<String, Object>>();
        for (Sale__c s : [
            SELECT Id, Name, Sale_Date__c, Order_Status__c,
                   Payment_Status__c, Total_Revenue__c, Total_Collected__c,
                   Balance_Due__c, Expected_Delivery_Date__c,
                   Web_Order_Ref__c,
                   (SELECT Brand__c, Packet_Type__c, Quantity__c,
                           Rate_Per_Kg__c, Packet_Count__c, Line_Amount__c
                    FROM Sale_Line_Items__r)
            FROM Sale__c
            WHERE Client__c = :client.Id
            ORDER BY Sale_Date__c DESC, Name DESC
            LIMIT 50
        ]) {
            List<Map<String, Object>> items = new List<Map<String, Object>>();
            for (Sale_Line_Item__c li : s.Sale_Line_Items__r) {
                items.add(new Map<String, Object>{
                    'brand'       => li.Brand__c,
                    'packetType'  => li.Packet_Type__c,
                    'quantityKg'  => li.Quantity__c,
                    'ratePerKg'   => li.Rate_Per_Kg__c,
                    'packets'     => li.Packet_Count__c,
                    'lineAmount'  => li.Line_Amount__c
                });
            }
            out.add(new Map<String, Object>{
                'saleId'        => s.Id,
                'saleName'      => s.Name,
                'orderRef'      => s.Web_Order_Ref__c,
                'saleDate'      => String.valueOf(s.Sale_Date__c),
                'status'        => s.Order_Status__c,
                'paymentStatus' => s.Payment_Status__c,
                'total'         => s.Total_Revenue__c,
                'collected'     => s.Total_Collected__c,
                'balanceDue'    => s.Balance_Due__c,
                'expectedDelivery' => s.Expected_Delivery_Date__c != null
                                      ? String.valueOf(s.Expected_Delivery_Date__c)
                                      : null,
                'items'         => items
            });
        }
        return out;
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    /** Remaining inventory minus KG blocked by active sales, per brand|packet. */
    private static Map<String, Decimal> availableByKey() {
        Map<String, Decimal> available = new Map<String, Decimal>();
        for (Inventory__c inv : [
            SELECT Brand__c, Packet_Type__c, Remaining_Quantity__c
            FROM Inventory__c WHERE Remaining_Quantity__c > 0
        ]) {
            available.put(inv.Brand__c + '|' + inv.Packet_Type__c,
                          inv.Remaining_Quantity__c);
        }
        for (AggregateResult ar : [
            SELECT Brand__c brand, Packet_Type__c packetType,
                   SUM(Quantity__c) qty
            FROM Sale_Line_Item__c
            WHERE Sale__r.Order_Status__c IN :BLOCKING_STATUSES
            AND Quantity__c != null
            GROUP BY Brand__c, Packet_Type__c
        ]) {
            String key = (String) ar.get('brand') + '|'
                       + (String) ar.get('packetType');
            if (available.containsKey(key)) {
                Decimal blocked = (Decimal) ar.get('qty');
                available.put(key, Math.max(0,
                    available.get(key) - (blocked != null ? blocked : 0)));
            }
        }
        return available;
    }

    /** Find a Client account whose phone ends with these 10 digits. */
    public static Account findClientByPhone(String digits) {
        // Fast path: indexed external-id field
        List<Account> hits = [
            SELECT Id, Name, Phone, Phone_Digits__c
            FROM Account
            WHERE Phone_Digits__c = :digits
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (!hits.isEmpty()) return hits[0];

        // Fallback: scan accounts whose Phone_Digits__c hasn't been backfilled
        for (Account a : [
            SELECT Id, Name, Phone, Phone_Digits__c
            FROM Account
            WHERE Phone != null AND Phone_Digits__c = null
            LIMIT 500
        ]) {
            if (normalizePhone(a.Phone) == digits) {
                a.Phone_Digits__c = digits;   // self-heal for next time
                try { update a; } catch (Exception e) {
                    System.debug('Phone_Digits__c backfill failed: ' + e.getMessage());
                }
                return a;
            }
        }
        return null;
    }

    private static Id clientRecordTypeId() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account' AND Name = 'Client'
            LIMIT 1
        ];
        return rts.isEmpty() ? null : rts[0].Id;
    }

    private static String left(String s, Integer max) {
        if (s == null) return null;
        s = s.trim();
        return s.length() > max ? s.substring(0, max) : s;
    }
}
