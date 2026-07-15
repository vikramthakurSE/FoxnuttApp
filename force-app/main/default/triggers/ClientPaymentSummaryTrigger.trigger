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

        // WhatsApp — query fresh Sale data with client phone
        Set<Id> saleIds = new Set<Id>();
        for (Client_Payment__c p : Trigger.new) {
            if (p.Sale__c != null) saleIds.add(p.Sale__c);
        }
        if (!saleIds.isEmpty()) {
            Map<Id, Sale__c> saleMap = new Map<Id, Sale__c>([
                SELECT Id, Name, Balance_Due__c,
                       Client__r.Name, Client__r.Phone
                FROM Sale__c WHERE Id IN :saleIds
            ]);
            WhatsAppHelper.dispatchPaymentReceived(Trigger.new, saleMap);
        }
    }
}
