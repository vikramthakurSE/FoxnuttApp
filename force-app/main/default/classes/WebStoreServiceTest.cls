@isTest
private class WebStoreServiceTest {

    private static void seedData() {
        insert new Inventory__c(
            Name                 = 'INV-TEST-1',
            Brand__c             = 'Holiday_250g',
            Packet_Type__c       = '250g',
            Total_Quantity__c    = 100,
            Remaining_Quantity__c = 100,
            Avg_Cost_Per_Kg__c   = 900
        );
        insert new Web_Product__c(
            Name               = 'Holiday Makhana 250g',
            Slug__c            = 'holiday-250g',
            Brand__c           = 'Holiday_250g',
            Packet_Type__c     = '250g',
            Pack_Size_Grams__c = 250,
            Price_Per_Kg__c    = 1200,
            Min_Order_Packets__c = 1,
            Is_Active__c       = true,
            Sort_Order__c      = 1
        );
    }

    private static WebStoreService.OrderInput orderInput(
        String phone, String ref, Integer packets
    ) {
        WebStoreService.OrderInput input = new WebStoreService.OrderInput();
        input.phone   = phone;
        input.name    = 'Test Buyer';
        input.businessName = 'Test Kirana Store';
        input.address = '12 MG Road, Bengaluru';
        input.note    = 'Please deliver in the morning';
        input.orderRef = ref;
        WebStoreService.OrderItemInput item =
            new WebStoreService.OrderItemInput();
        item.slug    = 'holiday-250g';
        item.packets = packets;
        input.items  = new List<WebStoreService.OrderItemInput>{ item };
        return input;
    }

    @isTest
    static void testNormalizePhone() {
        System.assertEquals('9008841421',
            WebStoreService.normalizePhone('+91 90088 41421'));
        System.assertEquals('9008841421',
            WebStoreService.normalizePhone('09008841421'));
        System.assertEquals('9008841421',
            WebStoreService.normalizePhone('919008841421'));
        System.assertEquals(null, WebStoreService.normalizePhone('12345'));
        System.assertEquals(null, WebStoreService.normalizePhone(null));
    }

    @isTest
    static void testCatalogAvailability() {
        seedData();
        Test.startTest();
        List<Map<String, Object>> products = WebStoreService.getCatalog();
        Test.stopTest();

        System.assertEquals(1, products.size());
        Map<String, Object> p = products[0];
        System.assertEquals('holiday-250g', p.get('slug'));
        System.assertEquals(400, p.get('availablePackets')); // 100 KG / 0.25
        System.assertEquals(true, p.get('inStock'));
        System.assertEquals(300.00,
            ((Decimal) p.get('pricePerPacket')).setScale(2)); // 1200 * 0.25
    }

    @isTest
    static void testNewCustomerOrderIsPendingApproval() {
        seedData();
        Test.startTest();
        WebStoreService.OrderResult res = WebStoreService.placeOrder(
            orderInput('+91 98765 43210', 'web-ref-001', 4));
        Test.stopTest();

        System.assertEquals(true, res.newCustomer);
        System.assertEquals('Pending Approval', res.status);
        System.assertEquals(1200.00, res.total); // 1 KG @ 1200

        Account acc = [SELECT Name, Phone_Digits__c, AccountSource,
                              Contact_Person__c
                       FROM Account WHERE Id = :res.accountId];
        System.assertEquals('Test Kirana Store', acc.Name);
        System.assertEquals('9876543210', acc.Phone_Digits__c);
        System.assertEquals('Web', acc.AccountSource);

        Sale__c sale = [SELECT Order_Status__c, Order_Source__c,
                               Web_Order_Ref__c,
                               (SELECT Quantity__c, Rate_Per_Kg__c,
                                       Cost_Per_Kg__c
                                FROM Sale_Line_Items__r)
                        FROM Sale__c WHERE Id = :res.saleId];
        System.assertEquals('Pending Approval', sale.Order_Status__c);
        System.assertEquals('Website', sale.Order_Source__c);
        System.assertEquals('web-ref-001', sale.Web_Order_Ref__c);
        System.assertEquals(1, sale.Sale_Line_Items__r.size());
        System.assertEquals(1.000, sale.Sale_Line_Items__r[0].Quantity__c);
        System.assertEquals(1200, sale.Sale_Line_Items__r[0].Rate_Per_Kg__c);
        // Cost snapshotted from inventory by the existing trigger
        System.assertEquals(900, sale.Sale_Line_Items__r[0].Cost_Per_Kg__c);
    }

    @isTest
    static void testExistingCustomerAutoConfirms() {
        seedData();
        insert new Account(
            Name  = 'Existing Client',
            Phone = '+91 91234 56789'
        );

        Test.startTest();
        WebStoreService.OrderResult res = WebStoreService.placeOrder(
            orderInput('9123456789', 'web-ref-002', 2));
        Test.stopTest();

        System.assertEquals(false, res.newCustomer);
        System.assertEquals('Confirmed', res.status);
        System.assertEquals('Existing Client', res.accountName);
        System.assertEquals(1,
            [SELECT COUNT() FROM Account WHERE Phone_Digits__c = '9123456789']);
    }

    @isTest
    static void testIdempotentReplayReturnsSameSale() {
        seedData();
        WebStoreService.OrderResult first = WebStoreService.placeOrder(
            orderInput('9876543210', 'web-ref-dup', 2));

        Test.startTest();
        WebStoreService.OrderResult second = WebStoreService.placeOrder(
            orderInput('9876543210', 'web-ref-dup', 2));
        Test.stopTest();

        System.assertEquals(true, second.duplicate);
        System.assertEquals(first.saleId, second.saleId);
        System.assertEquals(1,
            [SELECT COUNT() FROM Sale__c WHERE Web_Order_Ref__c = 'web-ref-dup']);
    }

    @isTest
    static void testInsufficientStockRejected() {
        seedData();
        Test.startTest();
        try {
            // 500 packets = 125 KG > 100 KG in stock
            WebStoreService.placeOrder(
                orderInput('9876543210', 'web-ref-003', 500));
            System.assert(false, 'Expected WebStoreException');
        } catch (WebStoreService.WebStoreException e) {
            System.assert(e.getMessage().contains('Not enough stock'),
                e.getMessage());
        }
        Test.stopTest();
        System.assertEquals(0,
            [SELECT COUNT() FROM Sale__c WHERE Web_Order_Ref__c = 'web-ref-003']);
    }

    @isTest
    static void testPendingOrderDoesNotBlockButCountsForWeb() {
        seedData();
        // Place a pending web order for 40 packets (10 KG)
        WebStoreService.placeOrder(orderInput('9876543210', 'web-ref-004', 40));

        Test.startTest();
        List<Map<String, Object>> products = WebStoreService.getCatalog();
        Test.stopTest();

        // Website availability: 100 - 10 = 90 KG → 360 packets
        System.assertEquals(360, products[0].get('availablePackets'));
    }

    @isTest
    static void testGetOrders() {
        seedData();
        WebStoreService.placeOrder(orderInput('9876543210', 'web-ref-005', 2));

        Test.startTest();
        List<Map<String, Object>> orders =
            WebStoreService.getOrders('+919876543210');
        Test.stopTest();

        System.assertEquals(1, orders.size());
        System.assertEquals('Pending Approval', orders[0].get('status'));
        List<Map<String, Object>> items =
            (List<Map<String, Object>>) orders[0].get('items');
        System.assertEquals(1, items.size());
        System.assertEquals('Holiday_250g', items[0].get('brand'));
    }

    @isTest
    static void testRestApi() {
        seedData();

        // GET catalog
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/catalog';
        RestContext.request.httpMethod = 'GET';
        WebStoreAPI.doGet();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('holiday-250g'));

        // POST order
        Test.startTest();
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/orders';
        RestContext.request.httpMethod = 'POST';
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(
            orderInput('9876543210', 'web-ref-rest', 2)));
        WebStoreAPI.doPost();
        Test.stopTest();
        System.assertEquals(201, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('Pending Approval'));

        // GET orders by phone
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/orders';
        RestContext.request.httpMethod = 'GET';
        RestContext.request.params.put('phone', '9876543210');
        WebStoreAPI.doGet();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('web-ref-rest'));

        // POST bad order → 400
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/orders';
        RestContext.request.httpMethod = 'POST';
        RestContext.request.requestBody = Blob.valueOf('{"items":[]}');
        WebStoreAPI.doPost();
        System.assertEquals(400, RestContext.response.statusCode);
    }
}
