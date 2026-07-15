public class WhatsAppHelper {

    // ── Config ─────────────────────────────────────────────────────────────
    private static WhatsApp_Config__mdt getConfig() {
        List<WhatsApp_Config__mdt> cfgs = [
            SELECT Access_Token__c, Phone_Number_ID__c
            FROM WhatsApp_Config__mdt LIMIT 1
        ];
        return cfgs.isEmpty() ? null : cfgs[0];
    }

    // ── Core send ──────────────────────────────────────────────────────────
    private static void sendMessage(String payload) {
        WhatsApp_Config__mdt cfg = getConfig();
        if (cfg == null) {
            System.debug('WA: config not found'); return;
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'https://graph.facebook.com/v19.0/' +
            cfg.Phone_Number_ID__c + '/messages'
        );
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + cfg.Access_Token__c);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(payload);
        req.setTimeout(10000);
        try {
            HttpResponse res = new Http().send(req);
            System.debug('WA [' + res.getStatusCode() + ']: ' + res.getBody());
        } catch (Exception e) {
            System.debug('WA error: ' + e.getMessage());
        }
    }

    // ── Format phone ───────────────────────────────────────────────────────
    private static String fmtPhone(String raw) {
        if (String.isBlank(raw)) return null;
        String d = raw.replaceAll('[^0-9]', '');
        if (d.length() == 10)        return '+91' + d;
        if (d.startsWith('0'))       return '+91' + d.substring(1);
        if (!d.startsWith('91'))     return '+91' + d;
        return d;
    }

    // ── Format quantity — show decimals for small amounts ─────────────────
    private static String fmtQty(Decimal qty) {
        if (qty == null) return '0';
        // If it's a whole number, show without decimals: 10 KG
        // If it has decimals, show with 2 decimal places: 0.25 KG
        if (qty == qty.setScale(0)) return qty.setScale(0).format();
        return qty.setScale(2).format();
    }
    private static String buildPayload(
        String to, String templateName, List<String> params
    ) {
        List<Object> parameters = new List<Object>();
        for (String p : params) {
            parameters.add(new Map<String, Object>{
                'type' => 'text',
                'text' => (p != null ? p : '-')
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'   => to,
            'type' => 'template',
            'template' => new Map<String, Object>{
                'name'     => templateName,
                'language' => new Map<String, Object>{ 'code' => 'en_US' },
                'components' => new List<Object>{
                    new Map<String, Object>{
                        'type'       => 'body',
                        'parameters' => parameters
                    }
                }
            }
        });
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. WELCOME — new client account created
    // Template: welcome_new_client  |  {{1}} = client name
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendWelcome(String phone, String clientName) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'welcome_new_client',
            new List<String>{ clientName }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. ORDER CONFIRMED — after sale + line items saved
    // Template: order_confirmed
    // {{1}} name, {{2}} order#, {{3}} products, {{4}} total, {{5}} delivery
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderConfirmed(
        String phone, String clientName, String saleName,
        String products, String total, String deliveryDate
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'order_confirmed',
            new List<String>{ clientName, saleName,
                              products, total, deliveryDate }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 3. OUT FOR DELIVERY
    // Template: order_out_for_delivery
    // {{1}} name, {{2}} order#, {{3}} balance due
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOutForDelivery(
        String phone, String clientName,
        String saleName, String balance
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'order_out_for_delivery',
            new List<String>{ clientName, saleName, balance }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. ORDER DELIVERED
    // Template: order_delivered
    // {{1}} name, {{2}} order#, {{3}} total, {{4}} collected, {{5}} balance
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderDelivered(
        String phone, String clientName, String saleName,
        String total, String collected, String balance
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'order_delivered',
            new List<String>{ clientName, saleName,
                              total, collected, balance }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. ORDER CANCELLED
    // Template: order_cancelled
    // {{1}} name, {{2}} order#
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderCancelled(
        String phone, String clientName, String saleName
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'order_cancelled',
            new List<String>{ clientName, saleName }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 6. PAYMENT RECEIVED
    // Template: payment_received
    // {{1}} name, {{2}} amount, {{3}} order#, {{4}} remaining balance
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendPaymentReceived(
        String phone, String clientName, String amount,
        String saleName, String remainingBalance
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'payment_received',
            new List<String>{ clientName, amount,
                              saleName, remainingBalance }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. ORDER FOLLOW-UP REMINDER (21+ days no order)
    // Template: order_followup_reminder
    // {{1}} name, {{2}} last order date, {{3}} stock + prices block
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderFollowUp(
        String phone, String clientName,
        String lastOrderDate, String stockBlock
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'order_followup_reminder',
            new List<String>{ clientName, lastOrderDate, stockBlock }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 8. PAYMENT FOLLOW-UP REMINDER (21+ days pending)
    // Template: payment_followup_reminder
    // {{1}} name, {{2}} amount due, {{3}} order#, {{4}} days pending
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendPaymentFollowUp(
        String phone, String clientName, String amountDue,
        String saleName, String daysPending
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, 'payment_followup_reminder',
            new List<String>{ clientName, amountDue,
                              saleName, daysPending }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // DISPATCHER METHODS — called from triggers/schedulers
    // Each collects data and calls the @future method above
    // ════════════════════════════════════════════════════════════════════════

    // ── 1. Welcome — called from AccountTrigger ────────────────────────────
    public static void dispatchWelcome(List<Account> accounts) {
        for (Account a : accounts) {
            if (String.isBlank(a.Phone)) continue;
            sendWelcome(a.Phone, a.Name);
        }
    }

    // ── 2. Order Confirmed — called from SaleLineItemHelper.onInsert ───────
    public static void dispatchOrderConfirmed(
        List<Sale__c> sales,
        Map<Id, List<Sale_Line_Item__c>> liMap
    ) {
        for (Sale__c s : sales) {
            if (String.isBlank(s.Client__r?.Phone)) continue;

            List<Sale_Line_Item__c> items = liMap.containsKey(s.Id)
                ? liMap.get(s.Id) : new List<Sale_Line_Item__c>();

            String products = '';
            Decimal total   = 0;
            for (Sale_Line_Item__c li : items) {
                Decimal qty  = li.Quantity__c    != null ? li.Quantity__c    : 0;
                Decimal rate = li.Rate_Per_Kg__c != null ? li.Rate_Per_Kg__c : 0;
                total += qty * rate;
                if (products != '') products += ', ';
                products += li.Brand__c + ' ' +
                    fmtQty(qty) + ' KG @ Rs' + rate.setScale(0);
            }

            String delivery = s.Expected_Delivery_Date__c != null
                ? s.Expected_Delivery_Date__c.format() : 'To be confirmed';

            sendOrderConfirmed(
                s.Client__r.Phone, s.Client__r.Name, s.Name,
                products,
                total.setScale(2).format(),
                delivery
            );
        }
    }

    // ── 3/4/5. Status Updates — called from SaleTrigger ───────────────────
    public static void dispatchStatusUpdate(List<Sale__c> sales) {
        for (Sale__c s : sales) {
            if (String.isBlank(s.Client__r?.Phone)) continue;

            String status = s.Order_Status__c;
            Decimal rev   = s.Total_Revenue__c    != null ? s.Total_Revenue__c    : 0;
            Decimal col   = s.Total_Collected__c  != null ? s.Total_Collected__c  : 0;
            Decimal bal   = s.Balance_Due__c      != null ? s.Balance_Due__c      : 0;

            if (status == 'Out for Delivery') {
                sendOutForDelivery(
                    s.Client__r.Phone, s.Client__r.Name, s.Name,
                    bal.setScale(0).format()
                );
            } else if (status == 'Delivered') {
                sendOrderDelivered(
                    s.Client__r.Phone, s.Client__r.Name, s.Name,
                    'Rs ' + rev.setScale(0).format(),
                    'Rs ' + col.setScale(0).format(),
                    bal.setScale(0).format()
                );
            } else if (status == 'Cancelled') {
                sendOrderCancelled(
                    s.Client__r.Phone, s.Client__r.Name, s.Name
                );
            }
        }
    }

    // ── 6. Payment Received — called from ClientPaymentSummaryTrigger ──────
    public static void dispatchPaymentReceived(
        List<Client_Payment__c> payments,
        Map<Id, Sale__c> saleMap
    ) {
        for (Client_Payment__c p : payments) {
            Sale__c s = saleMap.get(p.Sale__c);
            if (s == null || String.isBlank(s.Client__r?.Phone)) continue;

            Decimal amt = p.Amount__c       != null ? p.Amount__c       : 0;
            Decimal bal = s.Balance_Due__c  != null ? s.Balance_Due__c  : 0;

            sendPaymentReceived(
                s.Client__r.Phone, s.Client__r.Name,
                amt.setScale(0).format(),
                s.Name,
                bal.setScale(0).format()
            );
        }
    }

    // ── 7. Order Follow-Up — called from FollowUpNotificationHelper ─────────
    // Builds live stock block from Inventory with Selling_Price__c
    public static void dispatchOrderFollowUp(
        String phone, String clientName, String lastOrderDate
    ) {
        if (String.isBlank(phone)) return;

        // Build stock block from available inventory
        String stockBlock = '';
        for (Inventory__c inv : [
            SELECT Brand__c, Packet_Type__c,
                   Selling_Price__c, Remaining_Quantity__c
            FROM Inventory__c
            WHERE Remaining_Quantity__c > 0
            AND   Selling_Price__c != null
            ORDER BY Brand__c, Packet_Type__c
        ]) {
            stockBlock +=
                inv.Brand__c + ' (' + inv.Packet_Type__c + ')' +
                ' - ' + inv.Selling_Price__c.setScale(0) + '/kg' +
                ' (' + inv.Remaining_Quantity__c.setScale(0) + ' KG)\n';
        }
        if (String.isBlank(stockBlock))
            stockBlock = 'Fresh stock available. Contact us for details.';

        // Trim to fit WA limit
        if (stockBlock.length() > 300)
            stockBlock = stockBlock.substring(0, 297) + '...';

        sendOrderFollowUp(phone, clientName, lastOrderDate, stockBlock);
    }

    // ── 8. Payment Follow-Up — called from PaymentReminderHelper ───────────
    public static void dispatchPaymentFollowUp(
        String phone, String clientName,
        String amountDue, String saleName, Integer daysOld
    ) {
        if (String.isBlank(phone)) return;
        sendPaymentFollowUp(
            phone, clientName, amountDue,
            saleName, String.valueOf(daysOld)
        );
    }
}