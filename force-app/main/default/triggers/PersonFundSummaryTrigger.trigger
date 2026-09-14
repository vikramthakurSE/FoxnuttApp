trigger PersonFundSummaryTrigger on Person_Fund__c (
    after insert, after update, after delete, after undelete
) {
    // Business_Summary__c is the team total of these ledgers — rebuild it
    // whenever any ledger changes, whatever made the change.
    BusinessSummaryHelper.syncFromPersonFunds();
}
