trigger MfrPaymentSummaryTrigger on Manufacturer_Payment__c (
    after insert, after update, after delete
) {
    List<Manufacturer_Payment__c> newList =
        Trigger.isDelete ? null : Trigger.new;
    List<Manufacturer_Payment__c> oldList =
        Trigger.isInsert ? null : Trigger.old;

    // Update Business Summary + Person Funds
    BusinessSummaryHelper.onMfrPayment(newList, oldList);

    // Push notification on new payment
    if (Trigger.isAfter && Trigger.isInsert) {
        NotificationHelper.notifyMfrPayment(Trigger.new);
    }
}
