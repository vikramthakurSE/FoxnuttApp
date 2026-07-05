global class WeeklyPendingPaymentsScheduler
    implements Schedulable {

    global void execute(SchedulableContext sc) {
        EmailNotificationHelper.sendWeeklyPendingPayments();
    }
}