public with sharing class AccountClientController {

    @AuraEnabled(cacheable=true)
    public static List<Sale__c> getAccountData(Id accountId) {
        return [
            SELECT
                Id, Name, Sale_Date__c, Expected_Delivery_Date__c,
                Order_Status__c, Regional_Manager__c,
                Total_Revenue__c, Total_Collected__c,
                Balance_Due__c, Payment_Status__c,
                Total_Profit__c, Notes_Remarks__c,
                Effective_Revenue__c, Effective_Profit__c,
                Total_CD_Amount__c,
                (
                    SELECT Id, Brand__c, Packet_Type__c,
                           Quantity__c, Rate_Per_Kg__c,
                           GST_Applied__c, Line_Amount__c,
                           Line_Profit__c, Cost_Per_Kg__c
                    FROM Sale_Line_Items__r
                    ORDER BY CreatedDate ASC
                ),
                (
                    SELECT Id, Name, Payment_Date__c,
                           Amount__c, Mode_of_Payment__c,
                           Accepted_By__c, Reference__c
                    FROM Client_Payments__r
                    ORDER BY Payment_Date__c ASC
                )
            FROM Sale__c
            WHERE Client__c = :accountId
            ORDER BY Sale_Date__c DESC, CreatedDate DESC
            LIMIT 100
        ];
    }

    @AuraEnabled
    public static void savePayment(
        Id saleId,
        Decimal amount,
        String paymentDate,
        String mode,
        String acceptedBy,
        String reference,
        Decimal cdPercentage,
        Decimal cdAmount
    ) {
        // amount = actual cash received (real money, drives Person Funds)
        // cdAmount = discount given — added back via Settlement_Amount__c
        //            formula so the Sale's balance still zeroes out
        Client_Payment__c payment = new Client_Payment__c(
            Sale__c             = saleId,
            Amount__c           = amount,
            Payment_Date__c     = Date.valueOf(paymentDate),
            Mode_of_Payment__c  = mode,
            Accepted_By__c      = acceptedBy,
            Reference__c        = String.isBlank(reference)
                                  ? null : reference,
            CD_Percentage__c    = cdPercentage != null ? cdPercentage : 0,
            CD_Amount__c        = cdAmount != null ? cdAmount : 0
        );
        insert payment;
    }

    @AuraEnabled
    public static void updateSaleStatus(Id saleId, String status) {
        update new Sale__c(
            Id               = saleId,
            Order_Status__c  = status
        );
    }

    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getFollowUpStatus(Id accountId) {
        Account a = [
            SELECT Id, Follow_Up__c,
                   Follow_Up_Date__c,
                   Follow_Up_Notes__c,
                   Follow_Up_History__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        return new Map<String, Object>{
            'followUp'      => a.Follow_Up__c,
            'followUpDate'  => a.Follow_Up_Date__c != null
                               ? String.valueOf(a.Follow_Up_Date__c) : null,
            'followUpNotes' => a.Follow_Up_Notes__c,
            'followUpHistory' => a.Follow_Up_History__c
        };
    }

    @AuraEnabled
    public static void saveFollowUp(
        Id accountId,
        Boolean followUp,
        String notes
    ) {
        Account a = [
            SELECT Id, Follow_Up__c, Follow_Up_History__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];

        // Append new entry to history log
        String today   = Date.today().format();
        String action  = followUp ? 'Followed Up' : 'Cleared';
        String newEntry = '[' + today + '] ' + action;
        if (String.isNotBlank(notes)) {
            newEntry += ': ' + notes;
        }

        String existing = a.Follow_Up_History__c;
        a.Follow_Up_History__c = String.isBlank(existing)
            ? newEntry
            : newEntry + '\n' + existing; // newest first

        a.Follow_Up__c       = followUp;
        a.Follow_Up_Date__c  = followUp ? Date.today() : null;
        a.Follow_Up_Notes__c = notes; // current notes (for next pre-fill)

        update a;
    }

}