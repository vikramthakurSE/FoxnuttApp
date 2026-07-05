trigger ClientPaymentSummaryTrigger on Client_Payment__c (
    after insert, after update, after delete, after undelete
) {
    List<Client_Payment__c> newList =
        (Trigger.isDelete) ? null : Trigger.new;
    List<Client_Payment__c> oldList =
        (Trigger.isInsert || Trigger.isUndelete)
        ? null : Trigger.old;

    BusinessSummaryHelper.onClientPayment(newList, oldList);

    // Send email only on new payments
    if (Trigger.isInsert) {
        EmailNotificationHelper.sendPaymentReceived(Trigger.new);
    }
}