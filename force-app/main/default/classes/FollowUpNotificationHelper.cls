public class FollowUpNotificationHelper {

    public static void sendFollowUpReminders() {
        Date today  = Date.today();
        Date cutoff = today.addDays(-21);

        // Auto-uncheck Follow_Up__c after 1 week
        List<Account> toUncheck = [
            SELECT Id FROM Account
            WHERE Follow_Up__c = true
            AND Follow_Up_Date__c <= :today.addDays(-7)
        ];
        if (!toUncheck.isEmpty()) {
            for (Account a : toUncheck) {
                a.Follow_Up__c      = false;
                a.Follow_Up_Date__c = null;
            }
            update toUncheck;
        }

        // Find latest delivered sale per client
        Map<Id, Date>    lastDelivery   = new Map<Id, Date>();
        Map<Id, Sale__c> lastSaleByClient = new Map<Id, Sale__c>();

        for (Sale__c s : [
            SELECT Id, Name, Client__c,
                   Sale_Date__c, Expected_Delivery_Date__c,
                   Client__r.Name, Client__r.Phone
            FROM Sale__c
            WHERE Order_Status__c = 'Delivered'
            AND Client__c != null
        ]) {
            Date d = s.Expected_Delivery_Date__c != null
                ? s.Expected_Delivery_Date__c : s.Sale_Date__c;
            if (d == null) continue;
            if (!lastDelivery.containsKey(s.Client__c) ||
                d > lastDelivery.get(s.Client__c)) {
                lastDelivery.put(s.Client__c, d);
                lastSaleByClient.put(s.Client__c, s);
            }
        }

        // Filter 21+ days, skip if Follow_Up already checked
        Map<Id, Account> accountMap = new Map<Id, Account>([
            SELECT Id, Follow_Up__c
            FROM Account WHERE Id IN :lastDelivery.keySet()
        ]);

        Set<Id> eligibleSaleIds = new Set<Id>();
        List<Sale__c> toNotify  = new List<Sale__c>();

        for (Id cId : lastDelivery.keySet()) {
            if (lastDelivery.get(cId) > cutoff) continue;
            Account acc = accountMap.get(cId);
            if (acc != null && acc.Follow_Up__c) continue;
            Sale__c s = lastSaleByClient.get(cId);
            eligibleSaleIds.add(s.Id);
            toNotify.add(s);
        }

        if (toNotify.isEmpty()) return;

        // Push notifications
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = 'Follow_Up_Reminder' LIMIT 1
        ];
        if (!types.isEmpty()) {
            Id notifTypeId = types[0].Id;
            Set<String> recipientIds = new Set<String>();
            for (User u : [
                SELECT Id FROM User
                WHERE IsActive = true AND UserType = 'Standard'
            ]) { recipientIds.add(u.Id); }

            for (Sale__c s : toNotify) {
                Date lastDate   = lastDelivery.get(s.Client__c);
                Integer daysAgo = lastDate != null
                    ? lastDate.daysBetween(today) : 21;
                String phone    = s.Client__r.Phone != null
                    ? s.Client__r.Phone : 'No phone';
                String dateStr  = lastDate != null ? lastDate.format() : '-';

                Messaging.CustomNotification notif =
                    new Messaging.CustomNotification();
                notif.setTitle('Follow up: ' + s.Client__r.Name);
                String body = s.Client__r.Name + ' · ' + phone +
                    ' · Last order ' + daysAgo + ' days ago on ' +
                    dateStr;
                if (body.length() > 200) body = body.substring(0, 197) + '...';
                notif.setBody(body);
                notif.setNotificationTypeId(notifTypeId);
                notif.setTargetId(s.Client__c);
                try { notif.send(recipientIds); }
                catch (Exception e) {
                    System.debug('Follow-up notif failed: ' + e.getMessage());
                }

                // WhatsApp to client — only on Tuesdays and Saturdays
                // (push notification fires daily regardless)
                String dayName = Datetime.newInstance(
                    today, Time.newInstance(0,0,0,0)
                ).format('EEEE');
                Boolean isWaDay = dayName == 'Tuesday' || dayName == 'Saturday';

                if (isWaDay && String.isNotBlank(s.Client__r.Phone)) {
                    WhatsAppHelper.dispatchOrderFollowUp(
                        s.Client__r.Phone,
                        s.Client__r.Name,
                        dateStr
                    );
                }
            }
        }
    }
}