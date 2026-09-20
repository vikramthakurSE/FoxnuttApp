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
        input.pincode = '560001';
        input.districts = new List<String>{ 'BENGALURU URBAN' };
        input.state   = 'KARNATAKA';
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
        System.assertEquals(1200.00, res.total); // 1 KG @ 1200, GST included

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
        // 1200 includes GST, so the line keeps the net rate: 1200 / 1.05
        System.assertEquals(1142.86, sale.Sale_Line_Items__r[0].Rate_Per_Kg__c);
        // Cost snapshotted from inventory by the existing trigger
        System.assertEquals(900, sale.Sale_Line_Items__r[0].Cost_Per_Kg__c);
    }

    @isTest
    static void testExistingCustomerAutoConfirms() {
        seedData();
        Account a = new Account(
            Name  = 'Existing Client',
            Phone = '+91 91234 56789'
        );
        insert a;
        // Auto-confirm needs a vetted history: one delivered order.
        Sale__c prior = new Sale__c(
            Client__c       = a.Id,
            Sale_Date__c    = Date.today().addDays(-5),
            Order_Status__c = 'Delivered'
        );
        insert prior;
        insert new Sale_Line_Item__c(
            Sale__c        = prior.Id,
            Brand__c       = 'Holiday_250g',
            Packet_Type__c = '250g',
            Quantity__c    = 0.5,
            Rate_Per_Kg__c = 1200
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
    static void testOverduePaymentBlocksOrder() {
        seedData();
        Account a = new Account(
            Name  = 'Slow Payer',
            Phone = '+91 91234 56789'
        );
        insert a;
        // Delivered 60 days ago, nothing collected → ₹600 owed.
        Sale__c old = new Sale__c(
            Client__c       = a.Id,
            Sale_Date__c    = Date.today().addDays(-60),
            Order_Status__c = 'Delivered'
        );
        insert old;
        insert new Sale_Line_Item__c(
            Sale__c        = old.Id,
            Brand__c       = 'Holiday_250g',
            Packet_Type__c = '250g',
            Quantity__c    = 0.5,
            Rate_Per_Kg__c = 1200
        );

        List<WebStoreService.OverdueSale> due =
            WebStoreService.overdueSales(a.Id);
        System.assertEquals(1, due.size());
        System.assertEquals(600, due[0].balanceDue);
        System.assertEquals(60, due[0].daysOld);
        System.assertEquals(600, WebStoreService.sumDue(due));

        Test.startTest();
        Boolean blocked = false;
        try {
            WebStoreService.placeOrder(
                orderInput('9123456789', 'web-ref-due', 1));
        } catch (WebStoreService.PaymentDueException e) {
            blocked = true;
            System.assertEquals(600, e.totalDue);
            System.assertEquals(1, e.overdue.size());
            System.assert(e.getMessage().contains('45 days'));
        }
        System.assert(blocked, 'Order should have been refused');
        System.assertEquals(0,
            [SELECT COUNT() FROM Sale__c WHERE Web_Order_Ref__c = 'web-ref-due']);

        // REST surface: 402 with the structured payload.
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/orders';
        RestContext.request.httpMethod = 'POST';
        RestContext.request.requestBody = Blob.valueOf(JSON.serialize(
            orderInput('9123456789', 'web-ref-due-rest', 1)));
        WebStoreAPI.doPost();
        System.assertEquals(402, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('PAYMENT_OVERDUE'));

        // Settling the old order lifts the block.
        insert new Client_Payment__c(
            Sale__c            = old.Id,
            Amount__c          = 600,
            Payment_Date__c    = Date.today(),
            Mode_of_Payment__c = 'UPI',
            Accepted_By__c     = 'Vikram'
        );
        Test.stopTest();

        System.assert(WebStoreService.overdueSales(a.Id).isEmpty(),
            'Paid order must no longer block');
    }

    @isTest
    static void testRecentUnpaidOrderDoesNotBlock() {
        seedData();
        Account a = new Account(
            Name  = 'Fresh Client',
            Phone = '+91 91234 56789'
        );
        insert a;
        Sale__c recent = new Sale__c(
            Client__c       = a.Id,
            Sale_Date__c    = Date.today().addDays(-10),
            Order_Status__c = 'Delivered'
        );
        insert recent;
        insert new Sale_Line_Item__c(
            Sale__c        = recent.Id,
            Brand__c       = 'Holiday_250g',
            Packet_Type__c = '250g',
            Quantity__c    = 0.5,
            Rate_Per_Kg__c = 1200
        );
        System.assert(WebStoreService.overdueSales(a.Id).isEmpty());

        Test.startTest();
        WebStoreService.OrderResult res = WebStoreService.placeOrder(
            orderInput('9123456789', 'web-ref-recent', 1));
        Test.stopTest();
        System.assertEquals('Confirmed', res.status);

        // payment-due endpoint answers empty for this code
        Account saved = [SELECT Unique_Business_Code__c FROM Account
                         WHERE Id = :a.Id];
        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI =
            '/services/apexrest/store/v1/payment-due';
        RestContext.request.httpMethod = 'GET';
        RestContext.request.params.put('code', saved.Unique_Business_Code__c);
        WebStoreAPI.doGet();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('"totalDue":0'));
    }

    @isTest
    static void testOnlineOrderRecordsMethodAndExposesPaymentState() {
        seedData();
        WebStoreService.OrderInput input = orderInput('9876501234', 'web-ref-online', 2);
        input.paymentMethod = 'online';
        Test.startTest();
        WebStoreService.OrderResult res = WebStoreService.placeOrder(input);
        Test.stopTest();

        Sale__c s = [SELECT Payment_Method__c, Order_Status__c
                     FROM Sale__c WHERE Id = :res.saleId];
        System.assertEquals('Online', s.Payment_Method__c);
        System.assertEquals('Pending Approval', s.Order_Status__c);

        Map<String, Object> pay = WebStoreService.getOrderPayment('web-ref-online');
        System.assertEquals(res.saleName, pay.get('saleName'));
        System.assertEquals(false, pay.get('paid'));
        System.assertEquals(600, pay.get('balanceDue')); // 0.5 KG @ 1200, GST included
        System.assertEquals(null, WebStoreService.getOrderPayment('nope'));

        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/order-payment';
        RestContext.request.httpMethod = 'GET';
        RestContext.request.params.put('ref', 'web-ref-online');
        WebStoreAPI.doGet();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('"paid":false'));

        // COD is the default when the website sends nothing.
        System.assertEquals('Cash on Delivery', WebStoreService.paymentMethodOf(null));
        System.assertEquals('Online', WebStoreService.paymentMethodOf(' ONLINE '));
    }

    @isTest
    static void testSavedAddressesNewestFirstDedupedWithAccountFallback() {
        Account a = new Account(
            Name  = 'Address Client',
            Phone = '+91 93333 44444',
            ShippingStreet = '5 Station Road',
            ShippingCity   = 'Purnia'
        );
        insert a;
        insert new List<Sale__c>{
            new Sale__c(Client__c = a.Id, Sale_Date__c = Date.today().addDays(-30),
                        Order_Status__c = 'Confirmed',
                        Delivery_Address__c = '12 MG Road, Bengaluru'),
            new Sale__c(Client__c = a.Id, Sale_Date__c = Date.today().addDays(-2),
                        Order_Status__c = 'Confirmed',
                        Delivery_Address__c = 'Shop 3, Market Lane, Patna'),
            // Same place as the first, typed differently: listed once.
            new Sale__c(Client__c = a.Id, Sale_Date__c = Date.today().addDays(-1),
                        Order_Status__c = 'Confirmed',
                        Delivery_Address__c = '12 mg road,  Bengaluru.'),
            // Cancelled orders do not contribute addresses.
            new Sale__c(Client__c = a.Id, Sale_Date__c = Date.today(),
                        Order_Status__c = 'Cancelled',
                        Delivery_Address__c = 'Wrong Address 99'),
            new Sale__c(Client__c = a.Id, Sale_Date__c = Date.today().addDays(-5),
                        Order_Status__c = 'Confirmed')
        };
        String code = [SELECT Unique_Business_Code__c FROM Account
                       WHERE Id = :a.Id].Unique_Business_Code__c;

        Test.startTest();
        List<Map<String, Object>> saved = WebStoreService.getSavedAddresses(code);
        Test.stopTest();

        System.assertEquals(3, saved.size(), saved);
        System.assertEquals('12 mg road,  Bengaluru.', saved[0].get('address'));
        System.assertEquals('order', saved[0].get('source'));
        System.assertEquals('Shop 3, Market Lane, Patna', saved[1].get('address'));
        System.assertEquals('5 Station Road, Purnia', saved[2].get('address'));
        System.assertEquals('account', saved[2].get('source'));

        System.assert(WebStoreService.getSavedAddresses('NOPE00000').isEmpty());

        RestContext.request  = new RestRequest();
        RestContext.response = new RestResponse();
        RestContext.request.requestURI = '/services/apexrest/store/v1/addresses';
        RestContext.request.httpMethod = 'GET';
        RestContext.request.params.put('code', code);
        WebStoreAPI.doGet();
        System.assertEquals(200, RestContext.response.statusCode);
        System.assert(RestContext.response.responseBody.toString()
            .contains('Market Lane'));
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

    // ── Delivery rules by PIN code ───────────────────────────────────────

    /** Fixed numbers, so these tests do not follow edits to the live settings. */
    private static void useLaunchDeliverySettings() {
        DeliveryRules.Settings s = new DeliveryRules.Settings();
        s.localDistricts = new Set<String>{ 'BENGALURU URBAN', 'BENGALURU RURAL' };
        s.homeState    = 'KARNATAKA';
        s.defaultMinKg = 10;
        s.chargePerKg  = 5;
        s.maxCharge    = 90;
        s.brandMinKg   = new Map<String, Decimal>{ 'holiday' => 8 };
        DeliveryRules.cached = s;
    }

    private static WebStoreService.OrderInput outsideInput(
        String ref, Integer packets, String state, String district
    ) {
        WebStoreService.OrderInput input = orderInput('9876512345', ref, packets);
        input.pincode   = state == 'KARNATAKA' ? '570001' : '600001';
        input.districts = new List<String>{ district };
        input.state     = state;
        return input;
    }

    @isTest
    static void testMissingPincodeRejected() {
        seedData();
        WebStoreService.OrderInput input = orderInput('9876543210', 'web-ref-nopin', 1);
        input.pincode = '5600';
        Boolean refused = false;
        try {
            WebStoreService.placeOrder(input);
        } catch (WebStoreService.WebStoreException e) {
            refused = e.getMessage().contains('PIN code');
        }
        System.assert(refused, 'An order with a malformed PIN code must be refused');

        // An older website build sends no PIN code: old pricing, no rules.
        WebStoreService.OrderInput legacy = orderInput('9876543210', 'web-ref-legacy', 1);
        legacy.pincode = null;
        legacy.districts = null;
        legacy.state = null;
        WebStoreService.OrderResult res = WebStoreService.placeOrder(legacy);
        System.assertEquals(300, res.total);
        Sale__c s = [SELECT Delivery_Zone__c, Delivery_Charge__c FROM Sale__c WHERE Id = :res.saleId];
        System.assertEquals(null, s.Delivery_Zone__c);
        System.assertEquals(0, s.Delivery_Charge__c);
    }

    @isTest
    static void testBangaloreAcceptsSmallOrderWithoutCharge() {
        seedData();
        useLaunchDeliverySettings();
        WebStoreService.OrderInput input = orderInput('9876543210', 'web-ref-blr', 1);
        input.districts = new List<String>{ 'Bengaluru Rural' };
        WebStoreService.OrderResult res = WebStoreService.placeOrder(input);
        Sale__c s = [SELECT Delivery_Zone__c, Delivery_Charge__c, Delivery_Pincode__c
                     FROM Sale__c WHERE Id = :res.saleId];
        System.assertEquals('Local', s.Delivery_Zone__c);
        System.assertEquals(0, s.Delivery_Charge__c);
        System.assertEquals('560001', s.Delivery_Pincode__c);
    }

    @isTest
    static void testOutsideBangaloreBelowMinimumRejected() {
        seedData();
        useLaunchDeliverySettings();
        Boolean refused = false;
        try {
            // 7 KG of Holiday, minimum 8
            WebStoreService.placeOrder(outsideInput('web-ref-mys', 28, 'KARNATAKA', 'MYSURU'));
        } catch (WebStoreService.WebStoreException e) {
            refused = e.getMessage().contains('Holiday needs at least 8 KG (you have 7 KG)');
        }
        System.assert(refused, 'Holiday under 8 KG outside Bangalore must be refused');
        System.assertEquals(0, [SELECT COUNT() FROM Sale__c]);
    }

    @isTest
    static void testHomeStateMeetsMinimumWithoutCharge() {
        seedData();
        useLaunchDeliverySettings();
        WebStoreService.OrderResult res = WebStoreService.placeOrder(
            outsideInput('web-ref-mys-ok', 32, 'KARNATAKA', 'MYSURU'));   // 8 KG
        Sale__c s = [SELECT Delivery_Zone__c, Delivery_Charge__c, Order_Total__c
                     FROM Sale__c WHERE Id = :res.saleId];
        System.assertEquals('Home State', s.Delivery_Zone__c);
        System.assertEquals(0, s.Delivery_Charge__c);
        // 8 KG @ 1200 incl. GST; the 2-decimal net rate leaves a few paise.
        System.assert(Math.abs(s.Order_Total__c - 9600) < 0.10, s.Order_Total__c);
    }

    @isTest
    static void testOtherStateChargesPerKgWithCap() {
        seedData();
        useLaunchDeliverySettings();
        WebStoreService.OrderResult small = WebStoreService.placeOrder(
            outsideInput('web-ref-chn', 48, 'TAMIL NADU', 'CHENNAI'));    // 12 KG
        System.assertEquals(60, small.deliveryCharge);
        System.assert(Math.abs(small.total - (14400 + 60)) < 0.10, small.total);

        DeliveryRules.Quote capped = DeliveryRules.quote(
            DeliveryRules.ZONE_OTHER_STATE,
            new Map<String, Decimal>{ 'Holiday_250g' => 12, 'Gopala 250g' => 10 });
        System.assertEquals(90, capped.charge);   // 22 KG × 5 = 110, capped
        System.assert(capped.shortfalls.isEmpty());

        Sale__c s = [SELECT Balance_Due__c, Payment_Status__c FROM Sale__c WHERE Id = :small.saleId];
        System.assert(Math.abs(s.Balance_Due__c - 14460) < 0.10, s.Balance_Due__c);
        System.assertEquals('Unpaid', s.Payment_Status__c);
    }

    @isTest
    static void testEachBrandNeedsItsOwnMinimum() {
        useLaunchDeliverySettings();
        DeliveryRules.Quote q = DeliveryRules.quote(
            DeliveryRules.ZONE_HOME_STATE,
            new Map<String, Decimal>{
                'Holiday_250g'  => 5,
                'Holiday loose' => 3,     // Holiday 8 KG together — fine
                'Gopala 250g'   => 9.5    // under 10
            });
        System.assertEquals(1, q.shortfalls.size());
        System.assertEquals('Gopala', q.shortfalls[0].brand);
        System.assertEquals(17.5, q.totalKg);
        System.assertEquals(0, q.charge);
        System.assertEquals('Local', DeliveryRules.zoneFor(
            new List<String>{ 'RAMANAGARA', 'bengaluru  urban' }, 'KARNATAKA'));
        System.assertEquals('Other State', DeliveryRules.zoneFor(null, 'KERALA'));
        System.assertNotEquals(null, DeliveryRules.forWeb().get('chargePerKg'));
    }

    @isTest
    static void testModifyOrderKeepsMinimumAndRecalculatesCharge() {
        seedData();
        useLaunchDeliverySettings();
        WebStoreService.OrderResult res = WebStoreService.placeOrder(
            outsideInput('web-ref-mod', 48, 'TAMIL NADU', 'CHENNAI'));    // 12 KG
        String code = [SELECT Unique_Business_Code__c FROM Account
                       WHERE Id = :res.accountId].Unique_Business_Code__c;
        Sale_Line_Item__c li = [SELECT Id FROM Sale_Line_Item__c WHERE Sale__c = :res.saleId];

        Test.startTest();
        Boolean refused = false;
        try {
            WebStoreService.modifyOrder(code, res.saleId, new Map<Id, Integer>{ li.Id => 20 });
        } catch (WebStoreService.WebStoreException e) {
            refused = e.getMessage().contains('Holiday needs at least 8 KG');
        }
        System.assert(refused, 'Dropping under the minimum must be refused');

        WebStoreService.OrderEditResult r = WebStoreService.modifyOrder(
            code, res.saleId, new Map<Id, Integer>{ li.Id => 40 });        // 10 KG
        Test.stopTest();

        Sale__c s = [SELECT Delivery_Charge__c, Order_Total__c FROM Sale__c WHERE Id = :res.saleId];
        System.assertEquals(50, s.Delivery_Charge__c);
        System.assert(Math.abs(r.total - (12000 + 50)) < 0.10, r.total);
        System.assert(Math.abs(s.Order_Total__c - 12050) < 0.10, s.Order_Total__c);
    }
}
