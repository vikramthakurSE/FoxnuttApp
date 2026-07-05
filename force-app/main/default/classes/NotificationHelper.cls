public class NotificationHelper {

    // ── Custom Notification Type IDs (from Notification Builder) ──────────
    private static final Id TYPE_NEW_SALE      = '0MLdL000002m2ZRWAY';
    private static final Id TYPE_STATUS_CHANGED = '0MLdL000002m2b3WAA';
    private static final Id TYPE_PAYMENT        = '0MLdL000002m2cfWAA';
    private static final Id TYPE_DELIVERY       = '0MLdL000002m2eHWAQ';

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
        if (targetId != null) {
            notification.setTargetId(targetId);
        }

        try {
            notification.send(recipientIds);
        } catch (Exception e) {
            System.debug('Push notification failed: ' + e.getMessage());
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. NEW SALE CREATED
    // ════════════════════════════════════════════════════════════════════════
    public static void notifyNewSale(List<Sale__c> sales) {
        for (Sale__c s : sales) {
            String clientName = s.Client__r != null
                ? s.Client__r.Name : 'Client';
            Decimal rev = s.Total_Revenue__c != null
                ? s.Total_Revenue__c : 0;

            send(
                TYPE_NEW_SALE,
                '🛒 New Sale — ' + s.Name,
                clientName + ' · ₹' + rev.setScale(0) + ' · ' +
                (s.Order_Status__c != null ? s.Order_Status__c : 'Confirmed'),
                s.Id
            );
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
}