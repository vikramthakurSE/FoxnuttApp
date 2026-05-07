trigger SaleTrigger on Sale__c (after update) {

    Set<Id> deliveredNow   = new Set<Id>(); // just became Delivered
    Set<Id> undeliveredNow = new Set<Id>(); // was Delivered, now changed
    List<Id> statusChanged = new List<Id>();

    for (Sale__c s : Trigger.new) {
        Sale__c old = Trigger.oldMap.get(s.Id);
        if (s.Order_Status__c == old.Order_Status__c) continue;

        statusChanged.add(s.Id);

        if (s.Order_Status__c == 'Delivered') {
            // Status just changed TO Delivered — deduct inventory
            deliveredNow.add(s.Id);
        } else if (old.Order_Status__c == 'Delivered') {
            // Was Delivered, now changed AWAY — return stock
            undeliveredNow.add(s.Id);
        }
    }

    // Deduct inventory when delivered
    if (!deliveredNow.isEmpty()) {
        SaleLineItemHelper.onStatusDelivered(deliveredNow);
    }

    // Return inventory if un-delivered (e.g. Cancelled after Delivered)
    if (!undeliveredNow.isEmpty()) {
        SaleLineItemHelper.onStatusUndelivered(undeliveredNow);
    }

    // Send email when delivered
    if (!deliveredNow.isEmpty()) {
        List<Sale__c> full = [
            SELECT Id, Name, Sale_Date__c,
                   Order_Status__c, Regional_Manager__c,
                   Total_Revenue__c, Total_Profit__c,
                   Total_Collected__c, Balance_Due__c,
                   Payment_Status__c, Client__r.Name
            FROM Sale__c WHERE Id IN :deliveredNow
        ];
        EmailNotificationHelper.sendSaleDelivered(full);
    }
}
