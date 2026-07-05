trigger MfrPaymentSummaryTrigger on Manufacturer_Payment__c (
    after insert, after update, after delete, after undelete
) {
    List<Manufacturer_Payment__c> newList =
        (Trigger.isDelete) ? null : Trigger.new;
    List<Manufacturer_Payment__c> oldList =
        (Trigger.isInsert || Trigger.isUndelete) ? null : Trigger.old;

    BusinessSummaryHelper.onMfrPayment(newList, oldList);
}