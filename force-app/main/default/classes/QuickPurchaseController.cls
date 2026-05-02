public with sharing class QuickPurchaseController {

    @AuraEnabled(cacheable=true)
    public static List<Account> getSuppliers() {
        return [
            SELECT Id, Name FROM Account
            WHERE RecordType.Name = 'Supplier'
            AND IsActive__c = true
            ORDER BY Name ASC
        ];
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, List<String>> getPicklistValues() {
        Map<String, List<String>> result =
            new Map<String, List<String>>();

        List<String> brands = new List<String>();
        List<String> packetTypes = new List<String>();
        List<String> deliveryStatuses = new List<String>();
        List<String> teamMembers = new List<String>();
        List<String> paymentModes = new List<String>();

        for (Schema.PicklistEntry e :
            Purchase_Line_Item__c.Brand__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) brands.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Purchase_Line_Item__c.Packet_Type__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) packetTypes.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Purchase__c.Delivery_Status__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) deliveryStatuses.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Manufacturer_Payment__c.Paid_By__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) teamMembers.add(e.getValue());
        }
        for (Schema.PicklistEntry e :
            Manufacturer_Payment__c.Mode_of_Payment__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) paymentModes.add(e.getValue());
        }

        result.put('brands', brands);
        result.put('packetTypes', packetTypes);
        result.put('deliveryStatuses', deliveryStatuses);
        result.put('teamMembers', teamMembers);
        result.put('paymentModes', paymentModes);
        return result;
    }

    @AuraEnabled
    public static String savePurchase(
        Purchase__c purchase,
        List<Purchase_Line_Item__c> lineItems,
        Boolean hasAdvancePayment,
        Decimal advanceAmount,
        String advanceDate,
        String advanceMode,
        String advancePaidBy,
        String advanceNotes
    ) {
        Savepoint sp = Database.setSavepoint();
        try {
            if (lineItems == null || lineItems.isEmpty()) {
                throw new AuraHandledException(
                    'Please add at least one product line item.'
                );
            }
            for (Purchase_Line_Item__c li : lineItems) {
                if (String.isBlank(li.Brand__c))
                    throw new AuraHandledException(
                        'Please select a brand for all line items.');
                if (String.isBlank(li.Packet_Type__c))
                    throw new AuraHandledException(
                        'Please select packet type for all line items.');
                if (li.Quantity__c == null || li.Quantity__c <= 0)
                    throw new AuraHandledException(
                        'Quantity must be greater than 0.');
                if (li.Landing_Cost_Per_Kg__c == null
                    || li.Landing_Cost_Per_Kg__c <= 0)
                    throw new AuraHandledException(
                        'Landing cost must be greater than 0.');
            }

            insert purchase;

            for (Purchase_Line_Item__c li : lineItems) {
                li.Purchase__c = purchase.Id;
            }
            insert lineItems;

            if (hasAdvancePayment && advanceAmount != null
                && advanceAmount > 0) {
                insert new Manufacturer_Payment__c(
                    Purchase__c        = purchase.Id,
                    Amount_Paid__c     = advanceAmount,
                    Payment_Date__c    = Date.valueOf(advanceDate),
                    Mode_of_Payment__c = advanceMode,
                    Paid_By__c         = advancePaidBy,
                    Reference_Notes__c = String.isBlank(advanceNotes)
                                         ? null : advanceNotes
                );
            }

            return purchase.Id;

        } catch (AuraHandledException e) {
            Database.rollback(sp);
            throw e;
        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static void updateTax(Id purchaseId, Decimal taxAmount) {
        update new Purchase__c(
            Id            = purchaseId,
            Tax_Amount__c = taxAmount
        );
    }
}