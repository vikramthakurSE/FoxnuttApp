/**
 * Refunds for cancelled orders that hold payments.
 *
 * There is no payment gateway, so refunds are sent by hand over UPI. This
 * class keeps track of them on the Sale:
 *  - cancelling an order with money collected marks it Refund Pending with
 *    the amount owed, and pings staff to send it back
 *  - staff set Refund Status to Refunded (optionally with the UPI
 *    reference); the date is stamped and the client gets a WhatsApp
 *  - re-opening a cancelled order before the refund goes out clears it
 */
public without sharing class SaleRefundHelper {

    public static void beforeUpdate(List<Sale__c> news, Map<Id, Sale__c> olds) {
        for (Sale__c s : news) {
            Sale__c old = olds.get(s.Id);
            Decimal collected = s.Total_Collected__c == null ? 0 : s.Total_Collected__c;

            Boolean cancelledNow = s.Order_Status__c == 'Cancelled'
                && old.Order_Status__c != 'Cancelled';
            if (cancelledNow && collected > 0 && String.isBlank(s.Refund_Status__c)) {
                s.Refund_Status__c = 'Pending';
                if (s.Refund_Amount__c == null) s.Refund_Amount__c = collected;
            }

            Boolean reopened = old.Order_Status__c == 'Cancelled'
                && s.Order_Status__c != 'Cancelled';
            if (reopened && s.Refund_Status__c == 'Pending') {
                s.Refund_Status__c = null;
                s.Refund_Amount__c = null;
            }

            if (s.Refund_Status__c == 'Refunded' && old.Refund_Status__c != 'Refunded') {
                if (s.Refunded_On__c == null) s.Refunded_On__c = Date.today();
                if (s.Refund_Amount__c == null) s.Refund_Amount__c = collected;
            }
        }
    }

    public static void afterUpdate(List<Sale__c> news, Map<Id, Sale__c> olds) {
        Set<Id> dueNow = new Set<Id>();
        Set<Id> refundedNow = new Set<Id>();
        for (Sale__c s : news) {
            Sale__c old = olds.get(s.Id);
            if (s.Refund_Status__c == 'Pending' && old.Refund_Status__c != 'Pending')
                dueNow.add(s.Id);
            if (s.Refund_Status__c == 'Refunded' && old.Refund_Status__c != 'Refunded')
                refundedNow.add(s.Id);
        }
        if (!dueNow.isEmpty()) {
            NotificationHelper.notifyRefundDue([
                SELECT Id, Name, Refund_Amount__c, Client__r.Name
                FROM Sale__c WHERE Id IN :dueNow
            ]);
        }
        if (!refundedNow.isEmpty()) {
            WhatsAppHelper.dispatchRefundProcessed([
                SELECT Id, Name, Refund_Amount__c, Refund_Reference__c,
                       Client__r.Name, Client__r.Phone,
                       Client__r.Unique_Business_Code__c
                FROM Sale__c WHERE Id IN :refundedNow
            ]);
        }
    }
}
