for (CronTrigger job : [
    SELECT Id
    FROM CronTrigger
    WHERE CronJobDetail.Name = 'Foxnutt Quarterly Report'
]) {
    System.abortJob(job.Id);
}
