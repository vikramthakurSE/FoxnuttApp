global class FollowUpScheduler implements Schedulable {
    global void execute(SchedulableContext sc) {
        FollowUpNotificationHelper.sendFollowUpReminders();
    }
}