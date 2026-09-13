@isTest
private class PaymentReceiptControllerTest {

    @isTest
    static void testLoadsByRefAndById() {
        Account a = new Account(Name = 'Receipt Co', Phone = '+91 98450 11111');
        insert a;
        Sale__c s = new Sale__c(
            Client__c = a.Id, Sale_Date__c = Date.today(),
            Order_Status__c = 'Delivered', Web_Order_Ref__c = 'ref-receipt-1');
        insert s;
        insert new Inventory__c(
            Name = 'INV-receipt', Brand__c = 'Holiday_250g', Packet_Type__c = '250g',
            Total_Quantity__c = 100, Remaining_Quantity__c = 100,
            Avg_Cost_Per_Kg__c = 900);
        insert new Sale_Line_Item__c(
            Sale__c = s.Id, Brand__c = 'Holiday_250g', Packet_Type__c = '250g',
            Quantity__c = 1, Rate_Per_Kg__c = 1000);
        insert new Client_Payment__c(
            Sale__c = s.Id, Amount__c = 1000, Payment_Date__c = Date.today(),
            Mode_of_Payment__c = 'UPI', Accepted_By__c = 'Vikram',
            Reference__c = 'UTR123');

        Test.setCurrentPageReference(new PageReference('/apex/PaymentReceiptPDF'));
        ApexPages.currentPage().getParameters().put('ref', 'ref-receipt-1');
        PaymentReceiptController c1 = new PaymentReceiptController();
        System.assertEquals(true, c1.getFound());
        System.assertEquals('PAID', c1.getStatusLabel());
        System.assertEquals(1, c1.lines.size());

        Client_Payment__c cp = [SELECT Id FROM Client_Payment__c LIMIT 1];
        Test.setCurrentPageReference(new PageReference('/apex/PaymentReceiptPDF'));
        ApexPages.currentPage().getParameters().put('id', cp.Id);
        PaymentReceiptController c2 = new PaymentReceiptController();
        System.assertEquals(true, c2.getFound());
        System.assertEquals(1000, c2.getHeadlineAmount());

        Test.setCurrentPageReference(new PageReference('/apex/PaymentReceiptPDF'));
        ApexPages.currentPage().getParameters().put('ref', 'no-such-ref');
        PaymentReceiptController c3 = new PaymentReceiptController();
        System.assertEquals(false, c3.getFound());
    }

    @isTest
    static void testRenderAndRestEndpoint() {
        Account a = new Account(Name = 'PDF Co', Phone = '+91 98450 22222');
        insert a;
        Sale__c s = new Sale__c(
            Client__c = a.Id, Sale_Date__c = Date.today(),
            Order_Status__c = 'Confirmed', Web_Order_Ref__c = 'ref-receipt-2');
        insert s;

        // Test.isRunningTest() short-circuits getContentAsPDF(), so this
        // exercises the render path without the VF-in-test limitation.
        Blob pdf = PaymentReceiptService.renderForOrderRef('ref-receipt-2');
        System.assertNotEquals(null, pdf);
        System.assertEquals(null, PaymentReceiptService.renderForOrderRef(null));
        System.assertEquals(null, PaymentReceiptService.renderForOrderRef('missing-ref'));

        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/receipt';
        RestContext.request.httpMethod = 'GET';
        RestContext.request.params.put('ref', 'ref-receipt-2');
        WebStoreAPI.doGet();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals('application/pdf', RestContext.response.headers.get('Content-Type'));

        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/receipt';
        RestContext.request.httpMethod = 'GET';
        RestContext.request.params.put('ref', 'missing-ref');
        WebStoreAPI.doGet();
        System.assertEquals(404, RestContext.response.statusCode);
    }
}
