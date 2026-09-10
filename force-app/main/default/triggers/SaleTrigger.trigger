trigger SaleTrigger on Sale__c (after insert, after update, before delete) {

    // New sale WhatsApp + notification fired from SaleLineItemHelper.onInsert
    // (line items needed for product details)

    // BEFORE DELETE — return stock for a deleted Delivered sale. Cascade
    // delete of its line items does NOT fire their trigger, so we must
    // return inventory here (line items still exist at before-delete time).
    if (Trigger.isBefore && Trigger.isDelete) {
        SaleLineItemHelper.onSaleDelete(Trigger.old);
    }

    if (Trigger.isAfter && Trigger.isUpdate) {

        Set<Id> deliveredNow   = new Set<Id>();
        Set<Id> undeliveredNow = new Set<Id>();
        Set<Id> statusChanged  = new Set<Id>();
        Set<Id> approvedNow    = new Set<Id>();

        for (Sale__c s : Trigger.new) {
            Sale__c old = Trigger.oldMap.get(s.Id);
            if (s.Order_Status__c == old.Order_Status__c) continue;
            statusChanged.add(s.Id);
            if (s.Order_Status__c == 'Delivered')
                deliveredNow.add(s.Id);
            else if (old.Order_Status__c == 'Delivered')
                undeliveredNow.add(s.Id);
            // Web order approved — customer gets the order confirmation now
            if (old.Order_Status__c == 'Pending Approval'
                && s.Order_Status__c == 'Confirmed')
                approvedNow.add(s.Id);
        }

        // WhatsApp order confirmation for approved web orders
        if (!approvedNow.isEmpty()) {
            List<Sale__c> approvedSales = [
                SELECT Id, Name, Order_Status__c,
                       Expected_Delivery_Date__c,
                       Client__r.Name, Client__r.Phone,
                       Client__r.Unique_Business_Code__c
                FROM Sale__c WHERE Id IN :approvedNow
            ];
            Map<Id, List<Sale_Line_Item__c>> approvedLiMap =
                new Map<Id, List<Sale_Line_Item__c>>();
            for (Sale_Line_Item__c li : [
                SELECT Id, Sale__c, Brand__c, Packet_Type__c,
                       Quantity__c, Rate_Per_Kg__c
                FROM Sale_Line_Item__c WHERE Sale__c IN :approvedNow
            ]) {
                if (!approvedLiMap.containsKey(li.Sale__c))
                    approvedLiMap.put(li.Sale__c, new List<Sale_Line_Item__c>());
                approvedLiMap.get(li.Sale__c).add(li);
            }
            WhatsAppHelper.dispatchOrderConfirmed(approvedSales, approvedLiMap);
        }

        // Inventory adjustments
        if (!deliveredNow.isEmpty())
            SaleLineItemHelper.onStatusDelivered(deliveredNow);
        if (!undeliveredNow.isEmpty())
            SaleLineItemHelper.onStatusUndelivered(undeliveredNow);

        if (!statusChanged.isEmpty()) {
            // Re-query with all fields needed for email + WA + notification
            List<Sale__c> changed = [
                SELECT Id, Name, Sale_Date__c,
                       Order_Status__c, Regional_Manager__c,
                       Total_Revenue__c, Total_Profit__c,
                       Total_Collected__c, Balance_Due__c,
                       Payment_Status__c,
                       Client__r.Name, Client__r.Phone,
                       Client__r.Unique_Business_Code__c
                FROM Sale__c WHERE Id IN :statusChanged
            ];

            List<Sale__c> delivered  = new List<Sale__c>();
            List<Sale__c> statusOnly = new List<Sale__c>();

            for (Sale__c s : changed) {
                if (s.Order_Status__c == 'Delivered') delivered.add(s);
                else statusOnly.add(s);
            }

            // Emails
            if (!delivered.isEmpty())
                EmailNotificationHelper.sendSaleDelivered(delivered);
            if (!statusOnly.isEmpty())
                EmailNotificationHelper.sendSaleStatusChanged(statusOnly);

            // Push notifications
            NotificationHelper.notifyStatusChanged(changed);

            // WhatsApp — all status changes
            WhatsAppHelper.dispatchStatusUpdate(changed);
        }
    }
}