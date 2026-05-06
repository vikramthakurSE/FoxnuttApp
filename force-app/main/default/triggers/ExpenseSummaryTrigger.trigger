trigger ExpenseSummaryTrigger on Expense__c (
    after insert, after update, after delete, after undelete
) {
    List<Expense__c> newList =
        (Trigger.isDelete) ? null : Trigger.new;
    List<Expense__c> oldList =
        (Trigger.isInsert || Trigger.isUndelete) ? null : Trigger.old;

    BusinessSummaryHelper.onExpense(newList, oldList);
}
