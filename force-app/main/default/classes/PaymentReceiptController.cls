/**
 * Backs PaymentReceiptPDF. Two ways in:
 *   ?id=<Client_Payment__c Id>   — a receipt for one specific payment
 *   ?ref=<Sale__c.Web_Order_Ref__c> — the order's current payment state
 * (used by the website's "Download receipt" button, which only knows its
 * own order reference, never a Salesforce record Id).
 */
public with sharing class PaymentReceiptController {

    public Sale__c sale { get; private set; }
    public List<Sale_Line_Item__c> lines { get; private set; }
    public Client_Payment__c payment { get; private set; }   // null for the ref path
    public String generatedOn { get; private set; }

    public PaymentReceiptController() {
        lines = new List<Sale_Line_Item__c>();
        generatedOn = Datetime.now().format('d MMM yyyy, h:mm a');

        Map<String, String> params = ApexPages.currentPage().getParameters();
        Id paymentId = safeId(params.get('id'));
        String ref   = params.get('ref');

        if (paymentId != null) {
            List<Client_Payment__c> pays = [
                SELECT Id, Amount__c, CD_Amount__c, Settlement_Amount__c,
                       Payment_Date__c, Mode_of_Payment__c, Reference__c, Sale__c
                FROM Client_Payment__c WHERE Id = :paymentId LIMIT 1
            ];
            if (!pays.isEmpty()) {
                payment = pays[0];
                loadSale(payment.Sale__c);
            }
        } else if (String.isNotBlank(ref)) {
            List<Sale__c> sales = [
                SELECT Id FROM Sale__c WHERE Web_Order_Ref__c = :ref LIMIT 1
            ];
            if (!sales.isEmpty()) loadSale(sales[0].Id);
        }
    }

    private void loadSale(Id saleId) {
        List<Sale__c> rows = [
            SELECT Id, Name, Sale_Date__c, Order_Status__c, Payment_Method__c,
                   Payment_Status__c, Total_Revenue__c, Total_Collected__c,
                   Balance_Due__c, Delivery_Address__c,
                   Client__r.Name, Client__r.Contact_Person__c,
                   Client__r.Phone, Client__r.Unique_Business_Code__c
            FROM Sale__c WHERE Id = :saleId LIMIT 1
        ];
        if (rows.isEmpty()) return;
        sale = rows[0];
        lines = [
            SELECT Brand__c, Packet_Type__c, Quantity__c, Rate_Per_Kg__c, Line_Amount__c
            FROM Sale_Line_Item__c WHERE Sale__c = :saleId ORDER BY Id
        ];
    }

    public Boolean getFound() { return sale != null; }

    /** The amount line this receipt is about — this payment, or the order total collected. */
    public Decimal getHeadlineAmount() {
        if (payment != null) {
            return payment.Settlement_Amount__c != null
                ? payment.Settlement_Amount__c : payment.Amount__c;
        }
        return sale?.Total_Collected__c;
    }

    public String getStatusLabel() {
        Decimal bal = sale?.Balance_Due__c;
        Decimal col = sale?.Total_Collected__c;
        if (bal != null && bal <= 0 && col != null && col > 0) return 'PAID';
        if (col != null && col > 0) return 'PARTIALLY PAID';
        return 'UNPAID';
    }

    private static Id safeId(String s) {
        try { return String.isBlank(s) ? null : (Id) s; } catch (Exception e) { return null; }
    }
}
