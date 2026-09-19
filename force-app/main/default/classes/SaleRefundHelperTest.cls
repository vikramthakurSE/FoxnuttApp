@isTest
private class SaleRefundHelperTest {

    private static Sale__c paidSale(Decimal amount) {
        Account a = new Account(Name = 'Refund Client', Phone = '+91 94444 55555');
        insert a;
        Sale__c s = new Sale__c(Client__c = a.Id, Sale_Date__c = Date.today(),
                                Order_Status__c = 'Confirmed');
        insert s;
        if (amount > 0) {
            insert new Client_Payment__c(
                Sale__c = s.Id, Amount__c = amount, Payment_Date__c = Date.today(),
                Mode_of_Payment__c = 'UPI', Accepted_By__c = 'Vikram');
        }
        return s;
    }

    private static Sale__c reload(Id id) {
        return [SELECT Order_Status__c, Refund_Status__c, Refund_Amount__c,
                       Refunded_On__c, Refund_Reference__c
                FROM Sale__c WHERE Id = :id];
    }

    @isTest
    static void cancellingAPaidOrderOwesARefundUntilMarkedRefunded() {
        Sale__c s = paidSale(500);
        Test.startTest();
        update new Sale__c(Id = s.Id, Order_Status__c = 'Cancelled');
        Sale__c after = reload(s.Id);
        System.assertEquals('Pending', after.Refund_Status__c);
        System.assertEquals(500, after.Refund_Amount__c);

        update new Sale__c(Id = s.Id, Refund_Status__c = 'Refunded',
                           Refund_Reference__c = '612345678901');
        Test.stopTest();
        after = reload(s.Id);
        System.assertEquals('Refunded', after.Refund_Status__c);
        System.assertEquals(Date.today(), after.Refunded_On__c);
        System.assertEquals(500, after.Refund_Amount__c);
    }

    @isTest
    static void cancellingAnUnpaidOrderOwesNothing() {
        Sale__c s = paidSale(0);
        Test.startTest();
        update new Sale__c(Id = s.Id, Order_Status__c = 'Cancelled');
        Test.stopTest();
        System.assertEquals(null, reload(s.Id).Refund_Status__c);
    }

    @isTest
    static void reopeningBeforeTheRefundClearsIt() {
        Sale__c s = paidSale(300);
        Test.startTest();
        update new Sale__c(Id = s.Id, Order_Status__c = 'Cancelled');
        update new Sale__c(Id = s.Id, Order_Status__c = 'Confirmed');
        Test.stopTest();
        Sale__c after = reload(s.Id);
        System.assertEquals(null, after.Refund_Status__c);
        System.assertEquals(null, after.Refund_Amount__c);
    }

    @isTest
    static void orderHistoryCarriesTheRefund() {
        Sale__c s = paidSale(250);
        update new Sale__c(Id = s.Id, Order_Status__c = 'Cancelled');
        String phone = [SELECT Phone_Digits__c FROM Account
                        WHERE Name = 'Refund Client'].Phone_Digits__c;
        Test.startTest();
        List<Map<String, Object>> orders = WebStoreService.getOrders(phone);
        Test.stopTest();
        System.assertEquals('Pending', orders[0].get('refundStatus'));
        System.assertEquals(250, orders[0].get('refundAmount'));
    }
}
