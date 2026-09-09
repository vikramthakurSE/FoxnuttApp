/**
 * Backs the Pending Web Orders screen.
 *
 * Website orders from first-time customers land as Pending Approval, since
 * nothing yet ties that phone number to a real business. Approving one flips
 * it to Confirmed, and the existing SaleTrigger then blocks the stock and
 * sends the customer their order confirmation on WhatsApp.
 */
public with sharing class PendingWebOrdersController {

    public class PendingOrder {
        @AuraEnabled public Id      saleId          { get; set; }
        @AuraEnabled public String  saleName        { get; set; }
        @AuraEnabled public Date    saleDate        { get; set; }
        @AuraEnabled public String  clientName      { get; set; }
        @AuraEnabled public String  clientPhone     { get; set; }
        @AuraEnabled public String  businessCode    { get; set; }
        @AuraEnabled public String  deliveryAddress { get; set; }
        @AuraEnabled public Decimal total           { get; set; }
        @AuraEnabled public Boolean isNewCustomer   { get; set; }
        @AuraEnabled public List<String> items      { get; set; }
    }

    @AuraEnabled(cacheable=true)
    public static List<PendingOrder> getPendingOrders() {
        List<Sale__c> sales = [
            SELECT Id, Name, Sale_Date__c, Total_Revenue__c,
                   Delivery_Address__c, CreatedDate,
                   Client__c, Client__r.Name, Client__r.Phone,
                   Client__r.Unique_Business_Code__c,
                   Client__r.CreatedDate
            FROM Sale__c
            WHERE Order_Status__c = 'Pending Approval'
            ORDER BY CreatedDate DESC
            LIMIT 200
        ];
        if (sales.isEmpty()) return new List<PendingOrder>();

        Map<Id, List<String>> lines = new Map<Id, List<String>>();
        for (Sale_Line_Item__c li : [
            SELECT Sale__c, Brand__c, Packet_Type__c, Quantity__c,
                   Rate_Per_Kg__c
            FROM Sale_Line_Item__c
            WHERE Sale__c IN :sales
        ]) {
            if (!lines.containsKey(li.Sale__c))
                lines.put(li.Sale__c, new List<String>());
            Decimal qty = li.Quantity__c != null ? li.Quantity__c : 0;
            lines.get(li.Sale__c).add(
                li.Brand__c + ' — ' + qty.setScale(2) + ' KG @ ' +
                (li.Rate_Per_Kg__c != null
                    ? li.Rate_Per_Kg__c.setScale(0).format() : '0') + '/kg'
            );
        }

        List<PendingOrder> out = new List<PendingOrder>();
        for (Sale__c s : sales) {
            PendingOrder p        = new PendingOrder();
            p.saleId              = s.Id;
            p.saleName            = s.Name;
            p.saleDate            = s.Sale_Date__c;
            p.clientName          = s.Client__r?.Name;
            p.clientPhone         = s.Client__r?.Phone;
            p.businessCode        = s.Client__r?.Unique_Business_Code__c;
            p.deliveryAddress     = s.Delivery_Address__c;
            p.total               = s.Total_Revenue__c;
            // Account made within a minute of the sale means the website
            // created it for this order — worth flagging for a closer look.
            p.isNewCustomer = s.Client__r != null
                && s.Client__r.CreatedDate != null
                && s.CreatedDate.getTime() - s.Client__r.CreatedDate.getTime()
                   < 60000;
            p.items = lines.containsKey(s.Id)
                      ? lines.get(s.Id) : new List<String>();
            out.add(p);
        }
        return out;
    }

    /** Approve: stock is blocked and the customer is messaged by SaleTrigger. */
    @AuraEnabled
    public static void approveOrder(Id saleId) {
        setStatus(saleId, 'Confirmed');
    }

    /** Reject: nothing was ever reserved, so this only closes the record. */
    @AuraEnabled
    public static void rejectOrder(Id saleId) {
        setStatus(saleId, 'Cancelled');
    }

    private static void setStatus(Id saleId, String status) {
        if (saleId == null)
            throw new AuraHandledException('No order was selected.');
        Sale__c s = [
            SELECT Id, Order_Status__c FROM Sale__c WHERE Id = :saleId LIMIT 1
        ];
        if (s.Order_Status__c != 'Pending Approval') {
            throw new AuraHandledException(
                'That order is already ' + s.Order_Status__c + '.'
            );
        }
        try {
            update new Sale__c(Id = saleId, Order_Status__c = status);
        } catch (DmlException e) {
            // Most likely the stock ran out between the order and the
            // approval — surface that rather than a raw trigger error.
            throw new AuraHandledException(e.getDmlMessage(0));
        }
    }
}
