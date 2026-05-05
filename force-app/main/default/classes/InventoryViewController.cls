public with sharing class InventoryViewController {

    @AuraEnabled(cacheable=true)
    public static List<Inventory__c> getInventory() {
        return [
            SELECT Id, Name, Brand__c, Packet_Type__c,
                   Total_Quantity__c, Remaining_Quantity__c,
                   Quantity_Sold__c, Avg_Cost_Per_Kg__c,
                   Packet_Count__c, Shrinkage__c,
                   Last_Purchase_Date__c
            FROM Inventory__c
            ORDER BY Remaining_Quantity__c DESC NULLS LAST,
                     Brand__c ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getBrandDetail(
        String brand, String packetType
    ) {
        // Recent purchases for this brand
        List<Purchase_Line_Item__c> purchases = [
            SELECT Id, Purchase__r.Name,
                   Purchase__r.Order_Date__c,
                   Purchase__r.Supplier__r.Name,
                   Purchase__r.Delivery_Status__c,
                   Quantity__c, Landing_Cost_Per_Kg__c,
                   Line_Total__c, Shrinkage__c
            FROM Purchase_Line_Item__c
            WHERE Brand__c = :brand
            AND Packet_Type__c = :packetType
            ORDER BY Purchase__r.Order_Date__c DESC
            LIMIT 10
        ];

        // Recent sales for this brand
        List<Sale_Line_Item__c> sales = [
            SELECT Id, Sale__r.Name,
                   Sale__r.Sale_Date__c,
                   Sale__r.Client__r.Name,
                   Quantity__c, Rate_Per_Kg__c,
                   Line_Amount__c, Line_Profit__c
            FROM Sale_Line_Item__c
            WHERE Brand__c = :brand
            AND Packet_Type__c = :packetType
            ORDER BY Sale__r.Sale_Date__c DESC
            LIMIT 10
        ];

        return new Map<String, Object>{
            'purchases' => purchases,
            'sales'     => sales
        };
    }

    @AuraEnabled
    public static void updateShrinkage(
        Id inventoryId, Decimal shrinkage
    ) {
        // Re-query to get current totals so we can
        // correctly compute Remaining and Packet_Count
        Inventory__c current = [
            SELECT Id, Total_Quantity__c, Quantity_Sold__c, Packet_Type__c
            FROM Inventory__c
            WHERE Id = :inventoryId
            LIMIT 1
        ];

        Decimal total = current.Total_Quantity__c != null
                        ? current.Total_Quantity__c : 0;
        Decimal sold  = current.Quantity_Sold__c  != null
                        ? current.Quantity_Sold__c  : 0;
        Decimal shrink = shrinkage != null ? shrinkage : 0;
        Decimal remaining = Math.max(0, total - sold - shrink);

        // Packet_Count__c is a formula field — Salesforce recomputes
        // it automatically once Remaining_Quantity__c is updated.
        update new Inventory__c(
            Id                    = inventoryId,
            Shrinkage__c          = shrink,
            Remaining_Quantity__c = remaining
        );
    }
}