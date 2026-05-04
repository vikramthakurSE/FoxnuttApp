trigger PurchaseTrigger on Purchase__c (
    before insert, after insert, after update
) {
    if (Trigger.isBefore && Trigger.isInsert) {
        PurchaseHelper.setQuarter(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isInsert) {
        PurchaseHelper.setUniqueOrderCode(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isUpdate) {
        List<Id> statusChangedIds = new List<Id>();

        for (Purchase__c p : Trigger.new) {
            Purchase__c old = Trigger.oldMap.get(p.Id);
            if (p.Delivery_Status__c != old.Delivery_Status__c) {
                statusChangedIds.add(p.Id);
            }
        }

        if (!statusChangedIds.isEmpty()) {
            // Re-query with ALL fields needed by email — including Tax_Amount__c
            List<Purchase__c> full = [
                SELECT Id, Name, Unique_Order_Code__c,
                       Supplier__r.Name, Order_Date__c,
                       Delivery_Date__c, Quarter__c,
                       Delivery_Status__c,
                       Total_Order_Cost__c,
                       Total_Paid__c,
                       Tax_Amount__c,
                       Amount_Outstanding__c,
                       Manufacturer_Payment_Status__c
                FROM Purchase__c
                WHERE Id IN :statusChangedIds
            ];

            EmailNotificationHelper.sendPurchaseStatusChanged(full);
        }
    }
}
