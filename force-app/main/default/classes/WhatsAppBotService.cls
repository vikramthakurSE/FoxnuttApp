/**
 * @description : WhatsApp ordering bot — a small state machine per phone number.
 *
 *  Client: taps the Re-order button on the follow-up template (or types "order")
 *  Bot   : brand list, live from Inventory__c — brand + ₹/KG only, no stock shown
 *  Client: picks a brand
 *  Bot   : "How many KG?"
 *  Client: "5" / "5kg"
 *  Bot   : cart summary + [✅ Confirm] [➕ Add more] [❌ Cancel]
 *  Client: Confirm → phone is matched against Client Accounts; on match a
 *          Sale__c (Confirmed) + Sale_Line_Item__c rows are created — the
 *          existing SaleLineItemTrigger then validates stock, snapshots cost,
 *          and sends the order_confirmed WhatsApp template as the confirmation.
 *
 *  Numbers that don't match any Client Account are asked to contact us —
 *  no order is created for unverified phones.
 *
 *  State lives in WhatsApp_Session__c, keyed by phone (last 10 digits).
 *  Sessions reset after 30 minutes of silence. Free-form bot replies are
 *  allowed because the client messaged first (Meta 24-hour service window).
 **/
public without sharing class WhatsAppBotService implements Queueable, Database.AllowsCallouts {

    private static final Integer SESSION_TIMEOUT_MIN = 30;
    private String rawPayload;

    public WhatsAppBotService(String rawPayload) { this.rawPayload = rawPayload; }

    // ================================================================ entry

    public void execute(QueueableContext ctx) {
        try {
            Map<String, Object> root = (Map<String, Object>) JSON.deserializeUntyped(rawPayload);
            for (Object entryObj : listOf(root.get('entry'))) {
                for (Object changeObj : listOf(((Map<String, Object>) entryObj).get('changes'))) {
                    Map<String, Object> value =
                        (Map<String, Object>) ((Map<String, Object>) changeObj).get('value');
                    if (value == null) continue;
                    for (Object msgObj : listOf(value.get('messages'))) {
                        handleMessage((Map<String, Object>) msgObj);
                    }
                    // status updates (sent/delivered/read) also arrive here — ignored
                }
            }
        } catch (Exception e) {
            System.debug('WhatsAppBot payload error: ' + e.getMessage());
        }
    }

    private static List<Object> listOf(Object o) {
        return o instanceof List<Object> ? (List<Object>) o : new List<Object>();
    }

    /** JSON.deserializeUntyped returns Integer/Double for numbers — a direct
     *  (Decimal) cast on a Double blows up, so always convert via String. */
    private static Decimal dec(Object o) {
        return o == null ? null : Decimal.valueOf(String.valueOf(o));
    }

    // ============================================================== routing

    private void handleMessage(Map<String, Object> msg) {
        String waPhone = (String) msg.get('from');            // e.g. 919876543210
        String msgId   = (String) msg.get('id');
        String phone   = normalizePhone(waPhone);
        if (String.isBlank(phone)) return;

        // ---- load / create session, dedupe Meta retries -----------------
        WhatsApp_Session__c ses;
        List<WhatsApp_Session__c> existing = [
            SELECT Id, Stage__c, Cart_JSON__c, Last_Message_Id__c, LastModifiedDate
            FROM WhatsApp_Session__c WHERE Phone__c = :phone LIMIT 1
        ];
        if (!existing.isEmpty()) {
            ses = existing[0];
            if (ses.Last_Message_Id__c == msgId) return; // duplicate delivery
            if (ses.LastModifiedDate < Datetime.now().addMinutes(-SESSION_TIMEOUT_MIN)) {
                ses.Stage__c = 'MENU';
                ses.Cart_JSON__c = '[]';
            }
        } else {
            ses = new WhatsApp_Session__c(Phone__c = phone, Stage__c = 'MENU', Cart_JSON__c = '[]');
        }
        ses.Last_Message_Id__c = msgId;
        if (String.isBlank(ses.Cart_JSON__c)) ses.Cart_JSON__c = '[]';

        // ---- extract what the client said / tapped ----------------------
        String type = (String) msg.get('type');
        String text = '';
        String replyId = '';
        if (type == 'text') {
            text = ((String) ((Map<String, Object>) msg.get('text')).get('body')).trim();
        } else if (type == 'interactive') {
            Map<String, Object> inter = (Map<String, Object>) msg.get('interactive');
            Map<String, Object> reply = (Map<String, Object>)
                (inter.containsKey('list_reply') ? inter.get('list_reply') : inter.get('button_reply'));
            if (reply != null) replyId = (String) reply.get('id');
        } else if (type == 'button') {
            // Quick-reply tap on an approved template (the Re-order button on
            // order_followup_reminder arrives as this type) → treat as order intent
            replyId = 'reorder';
        } else {
            sendText(phone, 'Please use the buttons, or type *order* to see today\'s brands and rates. 🙏');
            upsert ses Phone__c;
            return;
        }

        // ---- route by button id first, then by stage --------------------
        if (replyId == 'cancel_order') {
            sendText(phone, 'Order cancelled. Type *order* anytime to start again. 👍');
            ses.Stage__c = 'MENU';
            ses.Cart_JSON__c = '[]';
        } else if (replyId == 'add_more' || replyId == 'reorder'
                   || (isOrderKeyword(text) && ses.Stage__c != 'QTY')) {
            sendProductList(phone);
            ses.Stage__c = 'MENU';
        } else if (replyId.startsWith('item|')) {
            handleItemPicked(ses, phone, replyId);
        } else if (replyId == 'confirm_order') {
            handleConfirm(ses, phone);
        } else if (ses.Stage__c == 'QTY') {
            handleQuantity(ses, phone, text);
        } else {
            sendText(phone, 'Namaste! 🙏 Type *order* to see today\'s makhana brands and rates.');
        }

        upsert ses Phone__c;
    }

    private static Boolean isOrderKeyword(String t) {
        String s = t == null ? '' : t.toLowerCase().trim();
        return s == 'order' || s == 'hi' || s == 'hello' || s == 'menu'
            || s == 'reorder' || s == 're-order' || s == 'stock' || s == 'rate';
    }

    /** Last 10 digits, digits only — same rule used to match Account.Phone */
    private static String normalizePhone(String raw) {
        if (String.isBlank(raw)) return null;
        String digits = raw.replaceAll('[^0-9]', '');
        return digits.length() > 10 ? digits.substring(digits.length() - 10) : digits;
    }

    // ======================================================== conversation

    /** Brand list from live inventory — brand + price per KG ONLY, no stock shown */
    private void sendProductList(String phone) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (CatalogItem it : getCatalog()) {
            if (!it.inStock) continue;
            rows.add(new Map<String, Object>{
                'id'          => 'item|' + it.brand + '|' + it.packetType,
                'title'       => (it.brand + ' ' + it.packetType).abbreviate(24),
                'description' => '₹' + it.price.setScale(0) + ' per KG'
            });
            if (rows.size() == 10) break; // WhatsApp list limit
        }
        if (rows.isEmpty()) {
            sendText(phone, 'Sorry, we are out of stock right now. We\'ll message you when fresh stock arrives! 🙏');
            return;
        }
        Map<String, Object> payload = basePayload(phone, 'interactive');
        payload.put('interactive', new Map<String, Object>{
            'type'   => 'list',
            'header' => new Map<String, Object>{ 'type' => 'text', 'text' => 'Today\'s Brands 🌸' },
            'body'   => new Map<String, Object>{ 'text' => 'Fresh phool makhana — tap to choose a brand:' },
            'action' => new Map<String, Object>{
                'button'   => 'View brands',
                'sections' => new List<Object>{
                    new Map<String, Object>{ 'title' => 'Makhana', 'rows' => rows }
                }
            }
        });
        callWhatsApp(payload);
    }

    private void handleItemPicked(WhatsApp_Session__c ses, String phone, String replyId) {
        List<String> parts = replyId.split('\\|');          // item|brand|packet
        if (parts.size() < 3) { sendProductList(phone); ses.Stage__c = 'MENU'; return; }
        CatalogItem picked;
        for (CatalogItem it : getCatalog()) {
            if (it.brand == parts[1] && it.packetType == parts[2]) { picked = it; break; }
        }
        if (picked == null || !picked.inStock) {
            sendText(phone, 'That item just went out of stock 😔 — type *order* to see what\'s available.');
            ses.Stage__c = 'MENU';
            return;
        }
        List<Object> cart = (List<Object>) JSON.deserializeUntyped(ses.Cart_JSON__c);
        cart.add(new Map<String, Object>{
            'brand' => picked.brand, 'packetType' => picked.packetType,
            'price' => picked.price, 'qty' => null, 'max' => picked.available
        });
        ses.Cart_JSON__c = JSON.serialize(cart);
        ses.Stage__c = 'QTY';
        sendText(phone, 'How many KG of *' + picked.brand + ' ' + picked.packetType
            + '*?\n\nReply with a number, e.g. *5* or *7.5*');
    }

    private void handleQuantity(WhatsApp_Session__c ses, String phone, String text) {
        // accept "5", "5kg", "5 kg", "7.5"
        Decimal qty;
        try {
            String cleaned = text == null ? '' : text.toLowerCase()
                .replace(',', '.').replaceAll('[^0-9.]', '');
            qty = String.isBlank(cleaned) ? null : Decimal.valueOf(cleaned);
        } catch (Exception e) { qty = null; }

        List<Object> cart = (List<Object>) JSON.deserializeUntyped(ses.Cart_JSON__c);
        if (cart.isEmpty()) { ses.Stage__c = 'MENU'; sendProductList(phone); return; }
        Map<String, Object> line = (Map<String, Object>) cart[cart.size() - 1];
        Decimal max = dec(line.get('max'));

        if (qty == null || qty <= 0) {
            sendText(phone, 'Please reply with just the number of KG, e.g. *5* or *7.5* 🙏');
            return;
        }
        if (max != null && qty > max) {
            sendText(phone, 'Sorry, we can\'t fulfil that much of *' + line.get('brand')
                + '* right now 😔 — please try a smaller quantity.');
            return;
        }
        line.put('qty', qty);
        ses.Cart_JSON__c = JSON.serialize(cart);
        ses.Stage__c = 'CONFIRM';
        sendCartSummary(phone, cart);
    }

    private void sendCartSummary(String phone, List<Object> cart) {
        Decimal total = 0;
        String lines = '';
        for (Object o : cart) {
            Map<String, Object> l = (Map<String, Object>) o;
            if (l.get('qty') == null) continue;
            Decimal amt = dec(l.get('price')) * dec(l.get('qty'));
            total += amt;
            lines += '• ' + l.get('brand') + ' ' + l.get('packetType') + ' — '
                   + dec(l.get('qty')).setScale(2) + ' KG = ₹' + amt.setScale(0) + '\n';
        }
        Map<String, Object> payload = basePayload(phone, 'interactive');
        payload.put('interactive', new Map<String, Object>{
            'type' => 'button',
            'body' => new Map<String, Object>{
                'text' => '*Your order* 🛒\n\n' + lines + '\n*Total: ₹' + total.setScale(0)
                        + '*\n_GST as applicable, final invoice with delivery._'
            },
            'action' => new Map<String, Object>{ 'buttons' => new List<Object>{
                btn('confirm_order', '✅ Confirm'),
                btn('add_more',      '➕ Add more'),
                btn('cancel_order',  '❌ Cancel')
            }}
        });
        callWhatsApp(payload);
    }

    private static Map<String, Object> btn(String id, String title) {
        return new Map<String, Object>{ 'type' => 'reply',
            'reply' => new Map<String, Object>{ 'id' => id, 'title' => title } };
    }

    private void handleConfirm(WhatsApp_Session__c ses, String phone) {
        List<Object> cart = (List<Object>) JSON.deserializeUntyped(ses.Cart_JSON__c);
        Boolean hasItems = false;
        for (Object o : cart) {
            if (((Map<String, Object>) o).get('qty') != null) { hasItems = true; break; }
        }
        if (!hasItems) { sendProductList(phone); ses.Stage__c = 'MENU'; return; }

        // Verify the sender: phone must match an existing Client Account.
        // Account.Phone formats vary (+91, spaces, dashes) so normalize in Apex.
        Account matched;
        for (Account a : [
            SELECT Id, Name, Phone FROM Account
            WHERE RecordType.DeveloperName = 'Client' AND Phone != null
        ]) {
            if (normalizePhone(a.Phone) == phone) { matched = a; break; }
        }

        if (matched == null) {
            ses.Stage__c = 'MENU';
            ses.Cart_JSON__c = '[]';
            sendText(phone, 'Sorry, we couldn\'t find your account for this number. '
                + 'Please call us to register, and we\'ll set you up right away! 🙏');
            return;
        }
        createOrder(ses, phone, matched, cart);
    }

    /** All callouts done above; safe to DML here.
     *  SaleLineItemTrigger validates stock + sends order_confirmed WhatsApp. */
    private void createOrder(WhatsApp_Session__c ses, String phone, Account acc, List<Object> cart) {
        Savepoint sp = Database.setSavepoint();
        try {
            Sale__c sale = new Sale__c(
                Client__c       = acc.Id,
                Order_Status__c = 'Confirmed',
                Sale_Date__c    = Date.today(),
                Notes_Remarks__c = 'Order placed via WhatsApp'
            );
            insert sale;

            List<Sale_Line_Item__c> lines = new List<Sale_Line_Item__c>();
            for (Object o : cart) {
                Map<String, Object> l = (Map<String, Object>) o;
                if (l.get('qty') == null) continue;
                lines.add(new Sale_Line_Item__c(
                    Sale__c        = sale.Id,
                    Brand__c       = (String) l.get('brand'),
                    Packet_Type__c = (String) l.get('packetType'),
                    Quantity__c    = dec(l.get('qty')),
                    Rate_Per_Kg__c = dec(l.get('price'))
                ));
            }
            insert lines; // trigger → stock check + cost snapshot + order_confirmed WhatsApp

            ses.Stage__c = 'MENU';
            ses.Cart_JSON__c = '[]';
            // no bot message needed — the order_confirmed template IS the confirmation
        } catch (Exception e) {
            Database.rollback(sp);
            ses.Stage__c = 'MENU';
            ses.Cart_JSON__c = '[]';
            // can't do a callout after DML in this txn — apologise via a fresh queueable
            System.enqueueJob(new SendTextJob(phone,
                'Sorry, that order could not be placed. Please type *order* to try again, '
                + 'or call us and we\'ll book it for you. 🙏'));
        }
    }

    /** Tiny helper queueable for the send-after-DML-failure case */
    public class SendTextJob implements Queueable, Database.AllowsCallouts {
        String phone; String message;
        public SendTextJob(String p, String m) { phone = p; message = m; }
        public void execute(QueueableContext c) { sendTextStatic(phone, message); }
    }

    // ============================================================== catalog

    public class CatalogItem {
        public String brand; public String packetType;
        public Decimal price; public Decimal available; public Boolean inStock;
    }

    private List<CatalogItem> catalogCache;

    /** Same availability rule as the app: remaining minus KG blocked by
     *  Confirmed / Out for Delivery orders. Availability is used only for
     *  internal validation — never shown to the client. */
    private List<CatalogItem> getCatalog() {
        if (catalogCache != null) return catalogCache;
        Map<String, Decimal> blocked = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Brand__c b, Packet_Type__c p, SUM(Quantity__c) q
            FROM Sale_Line_Item__c
            WHERE Sale__r.Order_Status__c IN ('Confirmed', 'Out for Delivery')
            AND Quantity__c != null
            GROUP BY Brand__c, Packet_Type__c
        ]) {
            blocked.put((String) ar.get('b') + '|' + (String) ar.get('p'), (Decimal) ar.get('q'));
        }
        catalogCache = new List<CatalogItem>();
        for (Inventory__c inv : [
            SELECT Brand__c, Packet_Type__c, Selling_Price__c, Remaining_Quantity__c
            FROM Inventory__c
            WHERE Selling_Price__c != null AND Remaining_Quantity__c > 0
            ORDER BY Brand__c, Packet_Type__c
        ]) {
            String key = inv.Brand__c + '|' + inv.Packet_Type__c;
            Decimal avail = inv.Remaining_Quantity__c
                          - (blocked.containsKey(key) ? blocked.get(key) : 0);
            CatalogItem it = new CatalogItem();
            it.brand = inv.Brand__c; it.packetType = inv.Packet_Type__c;
            it.price = inv.Selling_Price__c;
            it.available = avail > 0 ? avail : 0;
            it.inStock = avail >= 0.25;
            catalogCache.add(it);
        }
        return catalogCache;
    }

    // ================================================================ sends

    private void sendText(String phone, String message) { sendTextStatic(phone, message); }

    private static void sendTextStatic(String phone, String message) {
        Map<String, Object> payload = basePayload(phone, 'text');
        payload.put('text', new Map<String, Object>{ 'body' => message });
        callWhatsApp(payload);
    }

    private static Map<String, Object> basePayload(String phone, String type) {
        return new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'   => '91' + phone,
            'type' => type
        };
    }

    private static void callWhatsApp(Map<String, Object> payload) {
        try {
            WhatsApp_Config__mdt cfg = [
                SELECT Access_Token__c, Phone_Number_ID__c FROM WhatsApp_Config__mdt LIMIT 1];
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://graph.facebook.com/v19.0/' + cfg.Phone_Number_ID__c + '/messages');
            req.setMethod('POST');
            req.setHeader('Authorization', 'Bearer ' + cfg.Access_Token__c);
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(20000);
            req.setBody(JSON.serialize(payload));
            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() >= 300) {
                System.debug('WhatsApp send failed: ' + res.getStatusCode() + ' ' + res.getBody());
            }
        } catch (Exception e) {
            System.debug('WhatsApp send error: ' + e.getMessage());
        }
    }
}
