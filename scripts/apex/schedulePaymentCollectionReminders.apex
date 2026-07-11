System.schedule(
    'Foxnutt Payment Collection Reminders',
    '0 0 9 ? * MON,THU *',
    new PaymentCollectionReminderScheduler()
);
