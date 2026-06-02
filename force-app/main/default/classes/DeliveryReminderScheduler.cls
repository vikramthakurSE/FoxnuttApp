global class DeliveryReminderScheduler implements Schedulable {
    global void execute(SchedulableContext sc) {
        DeliveryReminderHelper.sendDailyReminders();
    }
}