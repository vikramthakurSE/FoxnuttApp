System.schedule(
    'Foxnutt Quarterly Report',
    '0 0 8 1 1,4,7,10 ? *',
    new QuarterlyReportScheduler()
);
