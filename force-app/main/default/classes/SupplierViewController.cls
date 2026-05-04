public with sharing class SupplierViewController {

    @AuraEnabled(cacheable=true)
    public static List<Purchase__c> getSupplierData(Id supplierId) {
        return [
            SELECT
                Id, Name, Order_Date__c, Delivery_Date__c,
                Delivery_Status__c, Quarter__c,
                Unique_Order_Code__c, Notes__c,
                Total_Order_Cost__c, Total_Paid__c, Tax_Amount__c,
                Amount_Outstanding__c,
                Manufacturer_Payment_Status__c,
                (
                    SELECT Id, Brand__c, Packet_Type__c,
                           Quantity__c, Landing_Cost_Per_Kg__c,
                           Line_Total__c, Packet_Count__c,
                           Shrinkage__c
                    FROM Purchase_Line_Items__r
                    ORDER BY CreatedDate ASC
                ),
                (
                    SELECT Id, Name, Payment_Date__c,
                           Amount_Paid__c, Mode_of_Payment__c,
                           Paid_By__c, Reference_Notes__c
                    FROM Manufacturer_Payments__r
                    ORDER BY Payment_Date__c ASC
                )
            FROM Purchase__c
            WHERE Supplier__c = :supplierId
            ORDER BY Order_Date__c DESC, CreatedDate DESC
            LIMIT 100
        ];
    }

    @AuraEnabled
    public static void saveMfrPayment(
        Id purchaseId,
        Decimal amount,
        String paymentDate,
        String mode,
        String paidBy,
        String notes
    ) {
        Manufacturer_Payment__c p = new Manufacturer_Payment__c(
            Purchase__c      = purchaseId,
            Amount_Paid__c   = amount,
            Payment_Date__c  = Date.valueOf(paymentDate),
            Mode_of_Payment__c = mode,
            Paid_By__c       = paidBy,
            Reference_Notes__c         = String.isBlank(notes) ? null : notes
        );
        insert p;
    }

    @AuraEnabled
    public static void updateDeliveryStatus(
        Id purchaseId, String status
    ) {
        Purchase__c p = new Purchase__c(
            Id                 = purchaseId,
            Delivery_Status__c = status
        );
        // Auto-set Delivery_Date__c when marked Received
        // so the email shows the real date not 'Today'
        if (status == 'Received') {
            p.Delivery_Date__c = Date.today();
        }
        update p;
    }
}