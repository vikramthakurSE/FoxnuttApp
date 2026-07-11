global class PaymentCollectionReminderScheduler implements Schedulable {
    global void execute(SchedulableContext sc) {
        FollowUpNotificationHelper.sendPaymentCollectionReminders();
    }
}
