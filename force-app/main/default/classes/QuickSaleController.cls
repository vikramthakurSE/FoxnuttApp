public with sharing class QuickSaleController {

    // ── Inventory + blocked quantities ────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getInventory() {
        List<Inventory__c> items = [
            SELECT Id, Brand__c, Packet_Type__c,
                   Remaining_Quantity__c, Avg_Cost_Per_Kg__c,
                   Packet_Count__c
            FROM Inventory__c
            WHERE Remaining_Quantity__c > 0
            ORDER BY Brand__c, Packet_Type__c
        ];

        // Blocked = active (Confirmed / Out for Delivery) sale line items
        Map<String, Decimal> blockedMap = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Brand__c brand, Packet_Type__c packetType,
                   SUM(Quantity__c) qty
            FROM Sale_Line_Item__c
            WHERE Sale__r.Order_Status__c IN ('Confirmed','Out for Delivery')
            AND Quantity__c != null
            GROUP BY Brand__c, Packet_Type__c
        ]) {
            String key = (String) ar.get('brand') + '|' +
                         (String) ar.get('packetType');
            Decimal qty = (Decimal) ar.get('qty');
            blockedMap.put(key, qty != null ? qty : 0);
        }

        // Attach blocked qty to each inventory item
        List<Map<String, Object>> enriched =
            new List<Map<String, Object>>();
        for (Inventory__c inv : items) {
            String key = inv.Brand__c + '|' + inv.Packet_Type__c;
            Decimal blocked = blockedMap.containsKey(key)
                              ? blockedMap.get(key) : 0;
            Decimal remaining = inv.Remaining_Quantity__c != null
                                ? inv.Remaining_Quantity__c : 0;
            enriched.add(new Map<String, Object>{
                'Id'                  => inv.Id,
                'Brand__c'            => inv.Brand__c,
                'Packet_Type__c'      => inv.Packet_Type__c,
                'Remaining_Quantity__c' => remaining,
                'Avg_Cost_Per_Kg__c'  => inv.Avg_Cost_Per_Kg__c,
                'Packet_Count__c'     => inv.Packet_Count__c,
                'blocked'             => blocked,
                'available'           => Math.max(0, remaining - blocked)
            });
        }
        return new Map<String, Object>{
            'inventory' => enriched
        };
    }

    // ── Picklist values ───────────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static Map<String, List<String>> getPicklistValues() {
        Map<String, List<String>> result =
            new Map<String, List<String>>();

        List<String> brands      = new List<String>();
        List<String> packetTypes = new List<String>();
        List<String> statuses    = new List<String>();
        List<String> managers    = new List<String>();

        for (Schema.PicklistEntry e :
            Sale_Line_Item__c.Brand__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) brands.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Sale_Line_Item__c.Packet_Type__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) packetTypes.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Sale__c.Order_Status__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) statuses.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Sale__c.Regional_Manager__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) managers.add(e.getValue());
        }

        result.put('brands',      brands);
        result.put('packetTypes', packetTypes);
        result.put('statuses',    statuses);
        result.put('managers',    managers);
        return result;
    }

    // ── Save Sale + Line Items ────────────────────────────────────────────
    @AuraEnabled
    public static String saveSale(
        Sale__c sale,
        List<Sale_Line_Item__c> lineItems
    ) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (lineItems == null || lineItems.isEmpty()) {
                throw new AuraHandledException(
                    'Please add at least one line item.'
                );
            }
            insert sale;
            for (Sale_Line_Item__c li : lineItems) {
                li.Sale__c = sale.Id;
            }
            insert lineItems;
            return sale.Id;
        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Update tax after save ─────────────────────────────────────────────
    @AuraEnabled
    public static void updateTax(Id purchaseId, Decimal taxAmount) {
        update new Purchase__c(
            Id            = purchaseId,
            Tax_Amount__c = taxAmount
        );
        List<Purchase_Line_Item__c> lineItems = [
            SELECT Id, Purchase__c, Brand__c, Packet_Type__c,
                   Quantity__c, Landing_Cost_Per_Kg__c
            FROM Purchase_Line_Item__c
            WHERE Purchase__c = :purchaseId
        ];
        if (!lineItems.isEmpty()) {
            EmailNotificationHelper.sendNewPurchaseAlert(lineItems);
        }
    }
}