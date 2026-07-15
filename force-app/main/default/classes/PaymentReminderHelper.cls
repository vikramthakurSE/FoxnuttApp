public class PaymentReminderHelper {

    public static void sendPaymentReminders() {
        Date today  = Date.today();
        Date cutoff = today.addDays(-21);

        // Only run on Tuesdays and Saturdays
        String dayName = Datetime.newInstance(
            today, Time.newInstance(0,0,0,0)
        ).format('EEEE');
        if (dayName != 'Tuesday' && dayName != 'Saturday') return;

        // Find clients with balance due on delivered sales 21+ days old
        Map<Id, Decimal> balanceByClient   = new Map<Id, Decimal>();
        Map<Id, Date>    oldestDueByClient = new Map<Id, Date>();
        Map<Id, String>  saleNameByClient  = new Map<Id, String>();
        Map<Id, String>  phoneByClient     = new Map<Id, String>();
        Map<Id, String>  nameByClient      = new Map<Id, String>();

        for (Sale__c s : [
            SELECT Id, Name, Client__c, Sale_Date__c,
                   Balance_Due__c,
                   Client__r.Name, Client__r.Phone
            FROM Sale__c
            WHERE Order_Status__c = 'Delivered'
            AND Balance_Due__c > 0
            AND Sale_Date__c <= :cutoff
            AND Client__c != null
        ]) {
            Id cId = s.Client__c;
            Decimal bal = s.Balance_Due__c != null ? s.Balance_Due__c : 0;
            balanceByClient.put(cId,
                (balanceByClient.containsKey(cId)
                 ? balanceByClient.get(cId) : 0) + bal);

            if (!oldestDueByClient.containsKey(cId) ||
                s.Sale_Date__c < oldestDueByClient.get(cId)) {
                oldestDueByClient.put(cId, s.Sale_Date__c);
                saleNameByClient.put(cId, s.Name);
            }
            phoneByClient.put(cId, s.Client__r.Phone);
            nameByClient.put(cId, s.Client__r.Name);
        }

        if (balanceByClient.isEmpty()) return;

        // Notification type for push
        List<CustomNotificationType> types = [
            SELECT Id FROM CustomNotificationType
            WHERE DeveloperName = 'Payment_Collection_Reminder' LIMIT 1
        ];
        Id notifTypeId = types.isEmpty() ? null : types[0].Id;

        Set<String> recipientIds = new Set<String>();
        for (User u : [
            SELECT Id FROM User
            WHERE IsActive = true AND UserType = 'Standard'
        ]) { recipientIds.add(u.Id); }

        for (Id clientId : balanceByClient.keySet()) {
            Decimal balance    = balanceByClient.get(clientId);
            Date    oldestDate = oldestDueByClient.get(clientId);
            String  saleName   = saleNameByClient.get(clientId);
            String  phone      = phoneByClient.get(clientId);
            String  clientName = nameByClient.get(clientId);
            Integer daysOld    = oldestDate != null
                ? oldestDate.daysBetween(today) : 21;

            // Push notification to admin team
            if (notifTypeId != null && !recipientIds.isEmpty()) {
                Messaging.CustomNotification notif =
                    new Messaging.CustomNotification();
                notif.setTitle('Payment due: ' + clientName);
                String body = clientName +
                    ' · Rs ' + balance.setScale(0).format() +
                    ' pending · ' + saleName +
                    ' (' + daysOld + ' days)';
                if (body.length() > 200)
                    body = body.substring(0, 197) + '...';
                notif.setBody(body);
                notif.setNotificationTypeId(notifTypeId);
                notif.setTargetId(clientId);
                try { notif.send(recipientIds); }
                catch (Exception e) {
                    System.debug('Payment notif failed: ' + e.getMessage());
                }
            }

            // WhatsApp reminder directly to client
            if (String.isNotBlank(phone)) {
                WhatsAppHelper.dispatchPaymentFollowUp(
                    phone, clientName,
                    balance.setScale(0).format(),
                    saleName, daysOld
                );
            }
        }
    }
}