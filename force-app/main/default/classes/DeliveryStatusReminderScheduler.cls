/**
 * @description : Scheduled twice daily — 11 AM with includeDueToday=true,
 * 2 PM with includeDueToday=false. See DeliveryStatusReminderHelper.
 **/
global class DeliveryStatusReminderScheduler implements Schedulable {
    private Boolean includeDueToday;

    global DeliveryStatusReminderScheduler(Boolean includeDueToday) {
        this.includeDueToday = includeDueToday;
    }

    global void execute(SchedulableContext sc) {
        DeliveryStatusReminderHelper.sendReminders(includeDueToday);
    }
}
