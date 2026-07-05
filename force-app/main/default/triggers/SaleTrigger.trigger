trigger SaleTrigger on Sale__c (after insert, after update) {

    // ── AFTER INSERT: new sale created → push notification ────────────────
    // Email already sent via SaleLineItemHelper.onInsert (line items needed)
    if (Trigger.isAfter && Trigger.isInsert) {
        List<Sale__c> withClient = [
            SELECT Id, Name, Order_Status__c,
                   Total_Revenue__c, Client__r.Name
            FROM Sale__c
            WHERE Id IN :Trigger.newMap.keySet()
        ];
        if (!withClient.isEmpty()) {
            NotificationHelper.notifyNewSale(withClient);
        }
    }

    // ── AFTER UPDATE: status changes ───────────────────────────────────────
    if (Trigger.isAfter && Trigger.isUpdate) {

        Set<Id> deliveredNow     = new Set<Id>();
        Set<Id> undeliveredNow   = new Set<Id>();
        Set<Id> statusChangedIds = new Set<Id>();

        for (Sale__c s : Trigger.new) {
            Sale__c oldS = Trigger.oldMap.get(s.Id);
            if (s.Order_Status__c == oldS.Order_Status__c) continue;

            statusChangedIds.add(s.Id);

            if (s.Order_Status__c == 'Delivered') {
                deliveredNow.add(s.Id);
            } else if (oldS.Order_Status__c == 'Delivered') {
                undeliveredNow.add(s.Id);
            }
        }

        // Inventory adjustments
        if (!deliveredNow.isEmpty()) {
            SaleLineItemHelper.onStatusDelivered(deliveredNow);
        }
        if (!undeliveredNow.isEmpty()) {
            SaleLineItemHelper.onStatusUndelivered(undeliveredNow);
        }

        // Send email + push notification for EVERY status change
        if (!statusChangedIds.isEmpty()) {
            List<Sale__c> changed = [
                SELECT Id, Name, Sale_Date__c,
                       Order_Status__c, Regional_Manager__c,
                       Total_Revenue__c, Total_Profit__c,
                       Total_Collected__c, Balance_Due__c,
                       Payment_Status__c, Client__r.Name
                FROM Sale__c WHERE Id IN :statusChangedIds
            ];

            // Delivered gets its own detailed email
            List<Sale__c> delivered = new List<Sale__c>();
            // All other status changes go through the generic status email
            List<Sale__c> statusOnly = new List<Sale__c>();

            for (Sale__c s : changed) {
                if (s.Order_Status__c == 'Delivered') {
                    delivered.add(s);
                } else {
                    statusOnly.add(s);
                }
            }

            if (!delivered.isEmpty()) {
                EmailNotificationHelper.sendSaleDelivered(delivered);
            }
            if (!statusOnly.isEmpty()) {
                EmailNotificationHelper.sendSaleStatusChanged(statusOnly);
            }

            // Push notification for ALL status changes (Delivered + others)
            NotificationHelper.notifyStatusChanged(changed);
        }
    }
}