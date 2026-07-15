global class PaymentReminderScheduler implements Schedulable {
    global void execute(SchedulableContext sc) {
        PaymentReminderHelper.sendPaymentReminders();
    }
}