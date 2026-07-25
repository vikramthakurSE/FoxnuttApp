/**
 * @description : Push-notification companion to DeliveryReminderHelper's
 * 8 AM email. Runs twice a day:
 *  - 11 AM: "Due Today" push (once) + "Delayed" push
 *  - 2 PM:  "Delayed" push only
 * Delayed = Expected_Delivery_Date__c in the past, status still
 * Confirmed/Out for Delivery — repeats every run until the order is
 * delivered (or cancelled).
 **/
public class DeliveryStatusReminderHelper {

    public static void sendReminders(Boolean includeDueToday) {
        Date today = Date.today();

        if (includeDueToday) {
            List<Sale__c> dueToday = [
                SELECT Id, Name, Expected_Delivery_Date__c,
                       Regional_Manager__c, Total_Revenue__c,
                       Balance_Due__c, Order_Status__c,
                       Client__r.Name, Client__r.Phone
                FROM Sale__c
                WHERE Expected_Delivery_Date__c = :today
                AND Order_Status__c IN ('Confirmed', 'Out for Delivery')
            ];
            if (!dueToday.isEmpty()) {
                NotificationHelper.notifyDeliveryReminder(dueToday, true);
            }
        }

        List<Sale__c> delayed = [
            SELECT Id, Name, Expected_Delivery_Date__c,
                   Regional_Manager__c, Total_Revenue__c,
                   Balance_Due__c, Order_Status__c,
                   Client__r.Name, Client__r.Phone
            FROM Sale__c
            WHERE Expected_Delivery_Date__c < :today
            AND Order_Status__c IN ('Confirmed', 'Out for Delivery')
        ];
        if (!delayed.isEmpty()) {
            NotificationHelper.notifyDeliveryDelayed(delayed);
        }
    }
}