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
        Inventory__c inv = new Inventory__c(
            Id          = inventoryId,
            Shrinkage__c = shrinkage
        );
        update inv;
    }
}