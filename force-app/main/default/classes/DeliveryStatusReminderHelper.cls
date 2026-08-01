/**
 * @description : Daily push notification for pending deliveries — every
 * undelivered order (Confirmed / Out for Delivery), categorized as
 * delayed / due today / tomorrow / upcoming. Runs twice a day:
 *  - 11 AM (isPrimary = true):  push if ANY delivery is pending
 *  - 2 PM  (isPrimary = false): push only if something is urgent
 *                               (delayed or due today) — avoids a second
 *                               daily ping when only future orders remain
 * Delayed = Expected_Delivery_Date__c in the past, still not delivered —
 * keeps appearing every day until the order is delivered or cancelled.
 **/
public class DeliveryStatusReminderHelper {

    public static void sendReminders(Boolean isPrimary) {
        Date today    = Date.today();
        Date tomorrow = today.addDays(1);

        List<Sale__c> pending = [
            SELECT Id, Name, Expected_Delivery_Date__c,
                   Total_Revenue__c, Order_Status__c,
                   Client__r.Name
            FROM Sale__c
            WHERE Order_Status__c IN ('Confirmed', 'Out for Delivery')
        ];
        if (pending.isEmpty()) return;

        Integer delayed = 0, dueToday = 0, dueTomorrow = 0, upcoming = 0;
        Decimal totalValue = 0;

        for (Sale__c s : pending) {
            totalValue += s.Total_Revenue__c != null ? s.Total_Revenue__c : 0;
            Date d = s.Expected_Delivery_Date__c;
            if (d == null)            upcoming++;      // no date set — treat as upcoming
            else if (d < today)       delayed++;
            else if (d == today)      dueToday++;
            else if (d == tomorrow)   dueTomorrow++;
            else                      upcoming++;
        }

        // 2 PM run only pings again when something actually needs action today
        if (!isPrimary && delayed == 0 && dueToday == 0) return;

        NotificationHelper.notifyPendingDeliveries(
            pending.size(), delayed, dueToday, dueTomorrow, upcoming, totalValue
        );
    }
}
