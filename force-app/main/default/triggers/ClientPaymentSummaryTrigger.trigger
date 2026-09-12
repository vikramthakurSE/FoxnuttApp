trigger ClientPaymentSummaryTrigger on Client_Payment__c (
    after insert, after update, after delete
) {
    List<Client_Payment__c> newList =
        Trigger.isDelete ? null : Trigger.new;
    List<Client_Payment__c> oldList =
        Trigger.isInsert ? null : Trigger.old;

    // Update Business Summary + Person Funds
    BusinessSummaryHelper.onClientPayment(newList, oldList);

    // On new payment: email + push notification (async after roll-up commits)
    // + WhatsApp to client
    if (Trigger.isAfter && Trigger.isInsert) {
        EmailNotificationHelper.sendPaymentReceived(
            new List<Client_Payment__c>(Trigger.new)
        );

        // WhatsApp — sent @future so Balance_Due__c is read after the
        // Settlement_Amount roll-up commits and the remaining balance in
        // the message is the post-payment figure, not the stale one.
        if (!System.isFuture() && !System.isBatch()) {
            WhatsAppHelper.dispatchPaymentReceivedAsync(
                Trigger.newMap.keySet());
        }
    }
}
