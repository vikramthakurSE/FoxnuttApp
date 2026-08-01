public class NotificationHelper {

    // ── Custom Notification Type IDs ──────────────────────────────────────
    private static final Id TYPE_NEW_SALE        = '0MLdL000002m2ZRWAY';
    private static final Id TYPE_STATUS_CHANGED  = '0MLdL000002m2b3WAA';
    private static final Id TYPE_PAYMENT         = '0MLdL000002m2cfWAA';
    private static final Id TYPE_DELIVERY        = '0MLdL000002m2eHWAQ';
    private static final Id TYPE_NEW_PURCHASE    = '0MLdL000002oTSHWA2';
    private static final Id TYPE_MFR_PAYMENT     = '0MLdL000002oTTtWAM';

    // ── Get all active standard users (same recipients as email) ──────────
    private static Set<String> getRecipientIds() {
        Set<String> ids = new Set<String>();
        for (User u : [
            SELECT Id FROM User
            WHERE IsActive = true
            AND UserType = 'Standard'
        ]) {
            ids.add(u.Id);
        }
        return ids;
    }

    // ── Core send method ───────────────────────────────────────────────────
    private static void send(
        Id notificationTypeId,
        String title,
        String body,
        Id targetId
    ) {
        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return;

        Messaging.CustomNotification notification =
            new Messaging.CustomNotification();
        notification.setTitle(title);
        notification.setBody(body);
        notification.setNotificationTypeId(notificationTypeId);

        // A custom notification MUST have a navigation target or the send
        // throws. Record-specific alerts pass a targetId; summary alerts
        // (e.g. pending deliveries) have none, so fall back to a page
        // reference that opens the Sales list.
        if (targetId != null) {
            notification.setTargetId(targetId);
        } else {
            notification.setTargetPageRef(
                '{"type":"standard__objectPage",' +
                '"attributes":{"objectApiName":"Sale__c","actionName":"list"},' +
                '"state":{}}'
            );
        }

        try {
            notification.send(recipientIds);
        } catch (Exception e) {
            System.debug('Push notification failed: ' + e.getMessage());
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. NEW SALE CREATED — called from SaleLineItemHelper after line items saved
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyNewSale(
        List<Sale__c> sales,
        Map<Id, List<Sale_Line_Item__c>> lineItemsMap
    ) {
        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return;

        List<OrgWideEmailAddress> owas = [
            SELECT Id FROM OrgWideEmailAddress LIMIT 1
        ];

        for (Sale__c s : sales) {
            String clientName = s.Client__r != null
                ? s.Client__r.Name : 'Client';

            // Build brand summary from line items
            List<Sale_Line_Item__c> items = lineItemsMap.containsKey(s.Id)
                ? lineItemsMap.get(s.Id)
                : new List<Sale_Line_Item__c>();

            Decimal totalRevenue = 0;
            String brandSummary  = '';
            for (Sale_Line_Item__c li : items) {
                Decimal qty  = li.Quantity__c != null ? li.Quantity__c : 0;
                Decimal rate = li.Rate_Per_Kg__c != null ? li.Rate_Per_Kg__c : 0;
                Decimal lineAmt = qty * rate;
                totalRevenue += lineAmt;
                if (brandSummary != '') brandSummary += ', ';
                brandSummary += li.Brand__c + ' ' +
                    qty.setScale(0) + 'KG @₹' + rate.setScale(0);
            }

            // Body: client · brands · amount · delivery date
            String deliveryInfo = s.Expected_Delivery_Date__c != null
                ? ' · Deliver: ' + s.Expected_Delivery_Date__c.format()
                : '';

            String body = clientName +
                ' · ' + brandSummary +
                ' · ₹' + totalRevenue.setScale(0).format() +
                deliveryInfo;

            Messaging.CustomNotification notif =
                new Messaging.CustomNotification();
            notif.setTitle('🛒 New Sale — ' + s.Name);
            notif.setBody(body.length() > 200
                ? body.substring(0, 197) + '...' : body);
            notif.setNotificationTypeId(TYPE_NEW_SALE);
            notif.setTargetId(s.Id);

            try {
                notif.send(recipientIds);
            } catch (Exception e) {
                System.debug('New sale notification failed: ' + e.getMessage());
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. SALE STATUS CHANGED (Confirmed / Out for Delivery / Delivered / Cancelled)
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyStatusChanged(List<Sale__c> sales) {
        for (Sale__c s : sales) {
            String clientName = s.Client__r != null
                ? s.Client__r.Name : 'Client';
            String status = s.Order_Status__c;

            String emoji = status == 'Delivered'      ? '✅'
                          : status == 'Out for Delivery' ? '🚚'
                          : status == 'Cancelled'        ? '❌'
                          : '📋';

            String bodyText;
            if (status == 'Delivered') {
                Decimal bal = s.Balance_Due__c != null
                    ? s.Balance_Due__c : 0;
                bodyText = clientName + ' · Balance: ₹' + bal.setScale(0);
            } else {
                bodyText = clientName + ' · Now: ' + status;
            }

            send(
                TYPE_STATUS_CHANGED,
                emoji + ' ' + s.Name + ' — ' + status,
                bodyText,
                s.Id
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 3. PAYMENT RECEIVED
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyPaymentReceived(
        List<Client_Payment__c> payments,
        Map<Id, Sale__c> saleMap
    ) {
        for (Client_Payment__c p : payments) {
            Sale__c s = saleMap.get(p.Sale__c);
            if (s == null) continue;

            String clientName = s.Client__r != null
                ? s.Client__r.Name : 'Client';
            Decimal amt = p.Amount__c != null ? p.Amount__c : 0;

            send(
                TYPE_PAYMENT,
                '💰 Payment Received — ₹' + amt.setScale(0),
                'From ' + clientName + ' · ' + s.Name,
                p.Sale__c
            );
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. DELIVERY REMINDER (today / tomorrow)
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyDeliveryReminder(
        List<Sale__c> sales, Boolean isToday
    ) {
        if (sales.isEmpty()) return;

        Decimal totalValue = 0;
        for (Sale__c s : sales) {
            totalValue += s.Total_Revenue__c != null
                ? s.Total_Revenue__c : 0;
        }

        String title = isToday
            ? '🚨 ' + sales.size() + ' Delivery(ies) Due TODAY'
            : '⏰ ' + sales.size() + ' Delivery(ies) Due Tomorrow';

        send(
            isToday ? TYPE_DELIVERY : TYPE_DELIVERY,
            title,
            'Total value: ₹' + totalValue.setScale(0) +
            ' · Tap to view orders',
            null
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4b. DELIVERY DELAYED — expected date has passed, still undelivered.
    // Fires twice daily (11 AM & 2 PM) until the order is marked Delivered.
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyDeliveryDelayed(List<Sale__c> sales) {
        if (sales.isEmpty()) return;

        Decimal totalValue = 0;
        for (Sale__c s : sales) {
            totalValue += s.Total_Revenue__c != null
                ? s.Total_Revenue__c : 0;
        }

        send(
            TYPE_DELIVERY,
            '⚠️ ' + sales.size() + ' Delivery(ies) DELAYED',
            'Past expected delivery date — total value: ₹' +
            totalValue.setScale(0) + ' · Tap to view orders',
            null
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4c. PENDING DELIVERIES — one daily summary of every undelivered order,
    // with the delayed / due-today ones called out first. Sent by
    // DeliveryStatusReminderHelper so the team gets a daily nudge whenever
    // anything is still awaiting delivery.
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyPendingDeliveries(
        Integer total, Integer delayed, Integer dueToday,
        Integer dueTomorrow, Integer upcoming, Decimal totalValue
    ) {
        if (total == null || total <= 0) return;

        List<String> parts = new List<String>();
        if (delayed     > 0) parts.add('⚠️ ' + delayed + ' delayed');
        if (dueToday    > 0) parts.add('📦 ' + dueToday + ' due today');
        if (dueTomorrow > 0) parts.add('🕒 ' + dueTomorrow + ' tomorrow');
        if (upcoming    > 0) parts.add('📅 ' + upcoming + ' upcoming');

        String body = String.join(parts, ' · ')
            + ' · ₹' + (totalValue != null ? totalValue.setScale(0) : 0)
            + ' · Tap to view';

        // Lead with the most urgent state in the title
        String title;
        if (delayed > 0)       title = '⚠️ ' + total + ' deliveries pending (' + delayed + ' delayed)';
        else if (dueToday > 0) title = '🚚 ' + total + ' deliveries pending (' + dueToday + ' today)';
        else                   title = '🚚 ' + total + ' deliver' + (total == 1 ? 'y' : 'ies') + ' pending';

        send(TYPE_DELIVERY, title, body, null);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. NEW PURCHASE CREATED
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyNewPurchase(
        List<Purchase_Line_Item__c> lineItems,
        Map<Id, Purchase__c> purchaseMap
    ) {
        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return;

        Map<Id, List<Purchase_Line_Item__c>> liMap =
            new Map<Id, List<Purchase_Line_Item__c>>();
        for (Purchase_Line_Item__c li : lineItems) {
            if (!liMap.containsKey(li.Purchase__c))
                liMap.put(li.Purchase__c,
                    new List<Purchase_Line_Item__c>());
            liMap.get(li.Purchase__c).add(li);
        }

        for (Id purId : liMap.keySet()) {
            Purchase__c p = purchaseMap.get(purId);
            if (p == null) continue;

            List<Purchase_Line_Item__c> items = liMap.get(purId);
            Decimal totalCost   = 0;
            String brandSummary = '';
            for (Purchase_Line_Item__c li : items) {
                Decimal qty  = li.Quantity__c != null ? li.Quantity__c : 0;
                Decimal cost = li.Landing_Cost_Per_Kg__c != null
                               ? li.Landing_Cost_Per_Kg__c : 0;
                totalCost += qty * cost;
                if (brandSummary != '') brandSummary += ', ';
                brandSummary += li.Brand__c + ' ' +
                    qty.setScale(0) + 'KG @Rs' + cost.setScale(0);
            }

            String supplier = p.Supplier__r != null
                ? p.Supplier__r.Name : 'Supplier';

            Messaging.CustomNotification notif =
                new Messaging.CustomNotification();
            notif.setTitle('📦 New Purchase — ' + p.Name);
            String body = supplier + ' · ' + brandSummary +
                ' · Rs ' + totalCost.setScale(0).format();
            notif.setBody(body.length() > 200
                ? body.substring(0, 197) + '...' : body);
            notif.setNotificationTypeId(TYPE_NEW_PURCHASE);
            notif.setTargetId(purId);
            try { notif.send(recipientIds); }
            catch (Exception e) {
                System.debug('New purchase notif failed: ' + e.getMessage());
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 6. PURCHASE STATUS CHANGED
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyPurchaseStatusChanged(
        List<Purchase__c> purchases
    ) {
        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return;

        for (Purchase__c p : purchases) {
            String status   = p.Delivery_Status__c;
            String emoji    = status == 'Received'         ? '✅'
                            : status == 'Out for Delivery' ? '🚚'
                            : status == 'Confirmed'        ? '📋'
                            : '📦';
            String supplier = p.Supplier__r != null
                ? p.Supplier__r.Name : 'Supplier';
            Decimal cost    = p.Total_Order_Cost__c != null
                ? p.Total_Order_Cost__c : 0;
            Decimal tax     = p.Tax_Amount__c != null
                ? p.Tax_Amount__c : 0;

            String body = supplier +
                ' · Rs ' + cost.setScale(0).format() +
                (tax > 0 ? ' + Rs ' + tax.setScale(0) + ' tax' : '') +
                ' · ' + status;

            Messaging.CustomNotification notif =
                new Messaging.CustomNotification();
            notif.setTitle(emoji + ' ' + p.Name + ' — ' + status);
            notif.setBody(body);
            notif.setNotificationTypeId(TYPE_NEW_PURCHASE);
            notif.setTargetId(p.Id);
            try { notif.send(recipientIds); }
            catch (Exception e) {
                System.debug('Purchase status notif failed: ' + e.getMessage());
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. MANUFACTURER PAYMENT
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyMfrPayment(
        List<Manufacturer_Payment__c> payments
    ) {
        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return;

        Set<Id> purchaseIds = new Set<Id>();
        for (Manufacturer_Payment__c mp : payments) {
            if (mp.Purchase__c != null) purchaseIds.add(mp.Purchase__c);
        }
        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Name, Supplier__r.Name
            FROM Purchase__c WHERE Id IN :purchaseIds
        ]);

        for (Manufacturer_Payment__c mp : payments) {
            Decimal amt     = mp.Amount_Paid__c != null ? mp.Amount_Paid__c : 0;
            Purchase__c p   = purchaseMap.get(mp.Purchase__c);
            String purName  = p != null ? p.Name : '';
            String supplier = (p != null && p.Supplier__r != null)
                ? p.Supplier__r.Name : 'Supplier';
            String paidBy   = mp.Paid_By__c != null ? mp.Paid_By__c : '-';

            Messaging.CustomNotification notif =
                new Messaging.CustomNotification();
            notif.setTitle('💸 Mfr Payment — Rs ' +
                amt.setScale(0).format());
            notif.setBody('To ' + supplier + ' · ' +
                purName + ' · Paid by ' + paidBy);
            notif.setNotificationTypeId(TYPE_MFR_PAYMENT);
            if (mp.Purchase__c != null) notif.setTargetId(mp.Purchase__c);
            try { notif.send(recipientIds); }
            catch (Exception e) {
                System.debug('Mfr payment notif failed: ' + e.getMessage());
            }
        }
    }
}