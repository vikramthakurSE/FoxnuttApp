global class QuarterlyReportScheduler implements Schedulable {

    global void execute(SchedulableContext sc) {
        // Only fire on the first day of a new quarter
        // Cron is set to Jan 1, Apr 1, Jul 1, Oct 1 at 8AM
        QuarterlyReportHelper.sendQuarterlyReport();
    }
}