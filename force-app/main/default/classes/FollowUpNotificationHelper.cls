public class FollowUpNotificationHelper {

    private static final Integer FOLLOW_UP_AGE_DAYS = 21;
    private static final Integer FOLLOW_UP_PAUSE_DAYS = 7;

    private class ClientDeliveryData {
        Map<Id, Date> lastDeliveryDateByClient = new Map<Id, Date>();
        Map<Id, Sale__c> lastSaleByClient = new Map<Id, Sale__c>();
        Map<Id, Decimal> outstandingByClient = new Map<Id, Decimal>();
        Map<Id, Integer> unpaidSaleCountByClient = new Map<Id, Integer>();
    }

    // Entry point - runs daily at 9 AM from FollowUpScheduler.
    public static void sendFollowUpReminders() {
        Date today = Date.today();
        Date cutoff = today.addDays(-FOLLOW_UP_AGE_DAYS);

        autoClearFollowUpFlags(today);

        ClientDeliveryData data = getClientDeliveryData();
        if (data.lastSaleByClient.isEmpty()) return;

        Set<Id> clientIds = data.lastSaleByClient.keySet();
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Follow_Up__c
            FROM Account
            WHERE Id IN :clientIds
        ]);

        sendSalesFollowUpReminders(
            today,
            cutoff,
            data,
            accountMap
        );
    }

    // Entry point - schedule separately, for example twice a week.
    public static void sendPaymentCollectionReminders() {
        Date today = Date.today();
        Date cutoff = today.addDays(-FOLLOW_UP_AGE_DAYS);

        ClientDeliveryData data = getClientDeliveryData();
        if (data.lastSaleByClient.isEmpty()) return;

        sendPaymentCollectionReminders(today, cutoff, data);
    }

    private static void autoClearFollowUpFlags(Date today) {
        List<Account> toUncheck = [
            SELECT Id, Follow_Up__c, Follow_Up_Date__c
            FROM Account
            WHERE Follow_Up__c = true
            AND Follow_Up_Date__c <= :today.addDays(-FOLLOW_UP_PAUSE_DAYS)
        ];

        for (Account a : toUncheck) {
            a.Follow_Up__c = false;
            a.Follow_Up_Date__c = null;
        }

        if (!toUncheck.isEmpty()) update toUncheck;
    }

    private static ClientDeliveryData getClientDeliveryData() {
        ClientDeliveryData data = new ClientDeliveryData();

        for (Sale__c s : [
            SELECT Id, Name, Client__c,
                   Sale_Date__c,
                   Expected_Delivery_Date__c,
                   Balance_Due__c,
                   Client__r.Name,
                   Client__r.Phone
            FROM Sale__c
            WHERE Order_Status__c = 'Delivered'
            AND Client__c != null
        ]) {
            Date deliveryDate = getDeliveryDate(s);
            if (deliveryDate == null) continue;

            if (!data.lastDeliveryDateByClient.containsKey(s.Client__c) ||
                deliveryDate > data.lastDeliveryDateByClient.get(s.Client__c)) {
                data.lastDeliveryDateByClient.put(s.Client__c, deliveryDate);
                data.lastSaleByClient.put(s.Client__c, s);
            }

            Decimal balance = s.Balance_Due__c != null ? s.Balance_Due__c : 0;
            if (balance > 0) {
                Decimal currentTotal = data.outstandingByClient.containsKey(s.Client__c)
                    ? data.outstandingByClient.get(s.Client__c)
                    : 0;
                Integer currentCount = data.unpaidSaleCountByClient.containsKey(s.Client__c)
                    ? data.unpaidSaleCountByClient.get(s.Client__c)
                    : 0;

                data.outstandingByClient.put(s.Client__c, currentTotal + balance);
                data.unpaidSaleCountByClient.put(s.Client__c, currentCount + 1);
            }
        }

        return data;
    }

    private static Set<Id> sendPaymentCollectionReminders(
        Date today,
        Date cutoff,
        ClientDeliveryData data
    ) {
        Set<Id> eligibleSaleIds = new Set<Id>();
        List<Sale__c> toNotify = new List<Sale__c>();

        for (Id clientId : data.outstandingByClient.keySet()) {
            Date lastDate = data.lastDeliveryDateByClient.get(clientId);
            Sale__c s = data.lastSaleByClient.get(clientId);
            if (lastDate == null || s == null) continue;
            if (lastDate > cutoff) continue;

            eligibleSaleIds.add(s.Id);
            toNotify.add(s);
        }

        if (toNotify.isEmpty()) return new Set<Id>();

        Id notifTypeId = getNotificationTypeId('Payment_Collection_Reminder');
        if (notifTypeId == null) {
            System.debug('Payment_Collection_Reminder notification type not found.');
            return new Set<Id>();
        }

        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return new Set<Id>();

        Map<Id, List<Sale_Line_Item__c>> liMap =
            getSaleLineItems(eligibleSaleIds);
        Set<Id> notifiedClientIds = new Set<Id>();

        for (Sale__c s : toNotify) {
            Date lastDate = data.lastDeliveryDateByClient.get(s.Client__c);
            Integer daysAgo = lastDate != null
                ? lastDate.daysBetween(today) : FOLLOW_UP_AGE_DAYS;
            Decimal outstanding = data.outstandingByClient.get(s.Client__c);
            Integer unpaidCount = data.unpaidSaleCountByClient.get(s.Client__c);

            String phone = s.Client__r.Phone != null
                ? s.Client__r.Phone : 'No phone';
            String dateStr = lastDate != null ? lastDate.format() : '-';
            String products = buildProductSummary(liMap.get(s.Id));
            String pendingText = unpaidCount == 1
                ? '1 unpaid sale'
                : String.valueOf(unpaidCount) + ' unpaid sales';

            String title = 'Payment due: ' + s.Client__r.Name;
            String body = s.Client__r.Name +
                ' - ' + phone +
                ' - Rs ' + outstanding.setScale(0).format() + ' due' +
                ' - ' + pendingText +
                ' - Last delivery ' + daysAgo + ' days ago on ' + dateStr +
                ' - ' + products;
            if (body.length() > 200) body = body.substring(0, 197) + '...';

            Messaging.CustomNotification notif =
                new Messaging.CustomNotification();
            notif.setTitle(title);
            notif.setBody(body);
            notif.setNotificationTypeId(notifTypeId);
            notif.setTargetId(s.Client__c);

            try {
                notif.send(recipientIds);
                notifiedClientIds.add(s.Client__c);
            } catch (Exception e) {
                System.debug('Payment follow-up failed: ' + e.getMessage());
            }
        }

        return notifiedClientIds;
    }

    private static void sendSalesFollowUpReminders(
        Date today,
        Date cutoff,
        ClientDeliveryData data,
        Map<Id, Account> accountMap
    ) {
        Set<Id> eligibleSaleIds = new Set<Id>();
        List<Sale__c> toNotify = new List<Sale__c>();

        for (Id clientId : data.lastDeliveryDateByClient.keySet()) {
            Date lastDate = data.lastDeliveryDateByClient.get(clientId);
            Sale__c s = data.lastSaleByClient.get(clientId);
            if (lastDate == null || s == null) continue;
            if (lastDate > cutoff) continue;

            Account acc = accountMap.get(clientId);
            if (acc != null && acc.Follow_Up__c == true) continue;

            eligibleSaleIds.add(s.Id);
            toNotify.add(s);
        }

        if (toNotify.isEmpty()) return;

        Id notifTypeId = getNotificationTypeId('Follow_Up_Reminder');
        if (notifTypeId == null) {
            System.debug('Follow_Up_Reminder notification type not found.');
            return;
        }

        Set<String> recipientIds = getRecipientIds();
        if (recipientIds.isEmpty()) return;

        Map<Id, List<Sale_Line_Item__c>> liMap =
            getSaleLineItems(eligibleSaleIds);

        for (Sale__c s : toNotify) {
            Date lastDate = data.lastDeliveryDateByClient.get(s.Client__c);
            Integer daysAgo = lastDate != null
                ? lastDate.daysBetween(today) : FOLLOW_UP_AGE_DAYS;

            String phone = s.Client__r.Phone != null
                ? s.Client__r.Phone : 'No phone';
            String dateStr = lastDate != null ? lastDate.format() : '-';
            String products = buildProductSummary(liMap.get(s.Id));

            String title = 'Follow up: ' + s.Client__r.Name;
            String body = s.Client__r.Name +
                ' - ' + phone +
                ' - Last order ' + daysAgo + ' days ago on ' + dateStr +
                ' - ' + products;
            if (body.length() > 200) body = body.substring(0, 197) + '...';

            Messaging.CustomNotification notif =
                new Messaging.CustomNotification();
            notif.setTitle(title);
            notif.setBody(body);
            notif.setNotificationTypeId(notifTypeId);
            notif.setTargetId(s.Client__c);

            try {
                notif.send(recipientIds);
            } catch (Exception e) {
                System.debug('Follow-up failed: ' + e.getMessage());
            }
        }
    }

    private static Date getDeliveryDate(Sale__c s) {
        return s.Expected_Delivery_Date__c != null
            ? s.Expected_Delivery_Date__c
            : s.Sale_Date__c;
    }

    private static Id getNotificationTypeId(String developerName) {
        List<CustomNotificationType> types = [
            SELECT Id
            FROM CustomNotificationType
            WHERE DeveloperName = :developerName
            LIMIT 1
        ];

        return types.isEmpty() ? null : types[0].Id;
    }

    private static Set<String> getRecipientIds() {
        Set<String> recipientIds = new Set<String>();
        for (User u : [
            SELECT Id FROM User
            WHERE IsActive = true
            AND UserType = 'Standard'
        ]) {
            recipientIds.add(u.Id);
        }
        return recipientIds;
    }

    private static Map<Id, List<Sale_Line_Item__c>> getSaleLineItems(
        Set<Id> saleIds
    ) {
        Map<Id, List<Sale_Line_Item__c>> liMap =
            new Map<Id, List<Sale_Line_Item__c>>();
        if (saleIds.isEmpty()) return liMap;

        for (Sale_Line_Item__c li : [
            SELECT Sale__c, Brand__c, Quantity__c
            FROM Sale_Line_Item__c
            WHERE Sale__c IN :saleIds
        ]) {
            if (!liMap.containsKey(li.Sale__c)) {
                liMap.put(li.Sale__c, new List<Sale_Line_Item__c>());
            }
            liMap.get(li.Sale__c).add(li);
        }

        return liMap;
    }

    private static String buildProductSummary(List<Sale_Line_Item__c> items) {
        if (items == null || items.isEmpty()) return 'Previous order';

        String products = '';
        for (Sale_Line_Item__c li : items) {
            Decimal qty = li.Quantity__c != null ? li.Quantity__c : 0;
            if (products != '') products += ', ';
            products += li.Brand__c + ' ' + qty.setScale(0) + ' KG';
        }

        return String.isBlank(products) ? 'Previous order' : products;
    }
}
