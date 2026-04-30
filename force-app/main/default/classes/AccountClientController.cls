public with sharing class AccountClientController {

    @AuraEnabled(cacheable=true)
    public static List<Sale__c> getAccountData(Id accountId) {
        return [
            SELECT
                Id, Name, Sale_Date__c,
                Order_Status__c, Regional_Manager__c,
                Total_Revenue__c, Total_Collected__c,
                Balance_Due__c, Payment_Status__c,
                Total_Profit__c, Profit_Margin__c,
                GST_Applied__c, Notes__c,

                -- Line Items
                (SELECT
                    Id, Brand__c, Packet_Type__c,
                    Quantity__c, Rate_Per_Kg__c,
                    GST_Applied__c, GST_Amount__c,
                    Line_Amount__c, Line_Profit__c,
                    Cost_Per_Kg__c, Packet_Count__c
                FROM Sale_Line_Items__r
                ORDER BY CreatedDate ASC),

                -- Payments
                (SELECT
                    Id, Name, Payment_Date__c,
                    Amount__c, Mode_of_Payment__c,
                    Accepted_By__c, Reference__c
                FROM Client_Payments__r
                ORDER BY Payment_Date__c ASC)

            FROM Sale__c
            WHERE Client__c = :accountId
            ORDER BY Sale_Date__c DESC, CreatedDate DESC
            LIMIT 100
        ];
    }
}