/**
 * Renders the colored PDF receipt (PaymentReceiptPDF.page). Used by the
 * public REST endpoint that both the website's "Download receipt" button
 * and the WhatsApp receipt link (Meta fetches it server-side) hit.
 *
 * getContentAsPDF() cannot run inside @future/batch/queueable Apex, so this
 * only ever runs synchronously — from the REST request itself, which is
 * exactly the context both callers use.
 */
public without sharing class PaymentReceiptService {

    /** One order's current receipt, by its website order reference. */
    public static Blob renderForOrderRef(String orderRef) {
        if (String.isBlank(orderRef)) return null;
        if (0 == [SELECT COUNT() FROM Sale__c WHERE Web_Order_Ref__c = :orderRef]) return null;
        if (Test.isRunningTest()) return Blob.valueOf('TEST-PDF');
        PageReference pr = Page.PaymentReceiptPDF;
        pr.getParameters().put('ref', orderRef);
        return pr.getContentAsPDF();
    }
}
