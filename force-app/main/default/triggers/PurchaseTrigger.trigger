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
        Set<Id> receivedNow   = new Set<Id>();
        List<Id> statusChanged = new List<Id>();

        for (Purchase__c p : Trigger.new) {
            Purchase__c old = Trigger.oldMap.get(p.Id);
            if (p.Delivery_Status__c != old.Delivery_Status__c) {
                statusChanged.add(p.Id);
                // Issue 3: trigger inventory creation only on → Received
                if (p.Delivery_Status__c == 'Received') {
                    receivedNow.add(p.Id);
                }
            }
        }

        // Create/update inventory for newly received purchases
        if (!receivedNow.isEmpty()) {
            PurchaseLineItemHelper.onStatusReceived(receivedNow);
        }

        // Send status-change email
        if (!statusChanged.isEmpty()) {
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
                FROM Purchase__c WHERE Id IN :statusChanged
            ];
            EmailNotificationHelper.sendPurchaseStatusChanged(full);

            // Push notification for purchase status change
            NotificationHelper.notifyPurchaseStatusChanged(full);
        }
    }
}
