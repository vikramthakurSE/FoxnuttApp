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
                Refund_Status__c, Refund_Amount__c,
                Refunded_On__c, Refund_Reference__c,
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

    /**
     * Mark a cancelled order's refund as sent. SaleRefundHelper stamps the
     * date and WhatsApps the client; this only decides what may be marked.
     * Orders cancelled before refund tracking existed have no Refund Status
     * yet, so Total Collected is accepted as the amount owed.
     */
    @AuraEnabled
    public static void markRefunded(Id saleId, String reference, String refundDate) {
        Sale__c s = [
            SELECT Id, Order_Status__c, Refund_Status__c,
                   Refund_Amount__c, Total_Collected__c
            FROM Sale__c WHERE Id = :saleId LIMIT 1
        ];
        if (s.Order_Status__c != 'Cancelled') {
            throw refundError('Only a cancelled order can be refunded.');
        }
        if (s.Refund_Status__c == 'Refunded') {
            throw refundError('This refund is already marked as sent.');
        }
        Decimal owed = s.Refund_Amount__c != null
            ? s.Refund_Amount__c
            : (s.Total_Collected__c != null ? s.Total_Collected__c : 0);
        if (owed <= 0) {
            throw refundError(
                'Nothing was collected on this order, so there is nothing to refund.');
        }
        update new Sale__c(
            Id                  = saleId,
            Refund_Status__c    = 'Refunded',
            Refund_Amount__c    = owed,
            Refund_Reference__c = String.isBlank(reference) ? null : reference.trim(),
            Refunded_On__c      = String.isBlank(refundDate)
                                  ? Date.today() : Date.valueOf(refundDate)
        );
    }

    private static AuraHandledException refundError(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    @AuraEnabled
    public static void updateSaleStatus(Id saleId, String status) {
        update new Sale__c(
            Id               = saleId,
            Order_Status__c  = status
        );
    }

    // Whether this client currently receives the WhatsApp order follow-up.
    @AuraEnabled(cacheable=false)
    public static Boolean getSendOrderFollowUp(Id accountId) {
        Account a = [
            SELECT Send_Order_FollowUp__c
            FROM Account WHERE Id = :accountId LIMIT 1
        ];
        return a.Send_Order_FollowUp__c;
    }

    // Toggle the per-client WhatsApp order follow-up on/off.
    @AuraEnabled
    public static void saveSendOrderFollowUp(Id accountId, Boolean enabled) {
        update new Account(Id = accountId, Send_Order_FollowUp__c = enabled);
    }

    // Default every Client to receiving the WhatsApp follow-up. A newly
    // (re)created checkbox leaves existing records unchecked, so this sets
    // them ON; safe to re-run (only touches records currently false).
    public static Integer backfillOrderFollowUpDefaults() {
        List<Account> toFix = [
            SELECT Id FROM Account
            WHERE RecordType.Name = 'Client'
            AND Send_Order_FollowUp__c = false
        ];
        for (Account a : toFix) a.Send_Order_FollowUp__c = true;
        if (!toFix.isEmpty()) update toFix;
        return toFix.size();
    }

}