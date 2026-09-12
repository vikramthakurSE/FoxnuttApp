@isTest
private class AxisCreditAlertHandlerTest {

    private static String body(String amount, String utr, String payer, String remark) {
        return '\n 11-09-2026\n\n Dear Vikram Kumar,\n\n' +
            ' Here\'s the summary of your transaction:\n\n' +
            ' Amount Credited:\n\n INR ' + amount + '\n\n' +
            ' Account Number:\n\n XX5214\n\n' +
            ' Date &amp; Time:\n\n 11-09-26, 17:25:31 IST\n\n' +
            ' Transaction Info:\n\n UPI/P2A/' + utr + '/' + payer + '/HDFC/' + remark +
            '\n\n Regards, Axis Bank Ltd.\n';
    }

    private static Sale__c deliveredSale(Account a, Decimal kg, Integer daysAgo) {
        insert new Inventory__c(
            Name = 'INV-' + daysAgo, Brand__c = 'Holiday_250g',
            Packet_Type__c = '250g', Total_Quantity__c = 100,
            Remaining_Quantity__c = 100, Avg_Cost_Per_Kg__c = 900);
        Sale__c s = new Sale__c(
            Client__c = a.Id, Sale_Date__c = Date.today().addDays(-daysAgo),
            Order_Status__c = 'Delivered');
        insert s;
        insert new Sale_Line_Item__c(
            Sale__c = s.Id, Brand__c = 'Holiday_250g', Packet_Type__c = '250g',
            Quantity__c = kg, Rate_Per_Kg__c = 1000);
        return [SELECT Id, Name, Balance_Due__c FROM Sale__c WHERE Id = :s.Id];
    }

    @isTest
    static void testParse() {
        AxisCreditAlertHandler.Parsed p = AxisCreditAlertHandler.parse(
            'INR 2,290.00 was credited to your A/c.',
            body('2,290.00', '129425753659', 'SRIMALINI', 'UPI'));
        System.assertEquals(2290, p.amount);
        System.assertEquals('129425753659', p.utr);
        System.assertEquals('SRIMALINI', p.payer);
        System.assertEquals('UPI', p.remark);
        System.assertEquals(true, p.isCredit);
        System.assertEquals(Datetime.newInstance(2026, 9, 11, 17, 25, 31), p.creditedAt);

        AxisCreditAlertHandler.Parsed d = AxisCreditAlertHandler.parse(
            'INR 500.00 was debited from your A/c.', 'Amount Debited: INR 500.00');
        System.assertEquals(false, d.isCredit);
    }

    @isTest
    static void testOrderNumberInRemarkBooksPayment() {
        Account a = new Account(Name = 'Green Grocers', Phone = '+91 98453 11111');
        insert a;
        Sale__c s = deliveredSale(a, 1.05, 60);   // ₹1050 owed

        Test.startTest();
        Bank_Credit_Alert__c alert = AxisCreditAlertHandler.process(
            'INR 1050.00 was credited to your A/c.',
            body('1050.00', '100000000001', 'SOMEONE ELSE', s.Name));
        Test.stopTest();

        System.assertEquals('Matched', alert.Status__c);
        System.assertEquals(s.Id, alert.Sale__c);
        Client_Payment__c cp = [SELECT Amount__c, Mode_of_Payment__c, Reference__c
                                FROM Client_Payment__c WHERE Sale__c = :s.Id];
        System.assertEquals(1050, cp.Amount__c);
        System.assertEquals('UPI', cp.Mode_of_Payment__c);
        System.assertEquals('100000000001', cp.Reference__c);
        System.assertEquals(0,
            [SELECT Balance_Due__c FROM Sale__c WHERE Id = :s.Id].Balance_Due__c);

        // Same UTR again → duplicate, no second payment.
        Bank_Credit_Alert__c again = AxisCreditAlertHandler.process(
            'INR 1050.00 was credited to your A/c.',
            body('1050.00', '100000000001', 'SOMEONE ELSE', s.Name));
        System.assertEquals('Duplicate', again.Status__c);
        System.assertEquals(1, [SELECT COUNT() FROM Client_Payment__c]);
    }

    @isTest
    static void testExactAmountAndPayerName() {
        Account a = new Account(Name = 'Srimalini Stores', Phone = '+91 98453 22222');
        Account b = new Account(Name = 'Other Shop', Phone = '+91 98453 33333');
        insert new List<Account>{ a, b };
        deliveredSale(a, 0.29, 50);   // ₹290
        deliveredSale(b, 2.0, 50);    // ₹2000

        Test.startTest();
        // Unique amount → matched without any remark
        Bank_Credit_Alert__c byAmount = AxisCreditAlertHandler.process(
            'INR 290.00 was credited to your A/c.',
            body('290.00', '200000000001', 'UNKNOWN PAYER', 'UPI'));
        System.assertEquals('Matched', byAmount.Status__c);
        System.assertEquals(a.Id, byAmount.Client__c);

        // Payer name → client b's remaining order, split over one order
        Bank_Credit_Alert__c byName = AxisCreditAlertHandler.process(
            'INR 500.00 was credited to your A/c.',
            body('500.00', '200000000002', 'OTHER SHOP PVT', 'UPI'));
        Test.stopTest();
        System.assertEquals('Matched', byName.Status__c);
        System.assertEquals(b.Id, byName.Client__c);
        System.assertEquals(1500,
            [SELECT Balance_Due__c FROM Sale__c WHERE Client__c = :b.Id].Balance_Due__c);
    }

    @isTest
    static void testPayerNameIsLearnedAndReused() {
        Account a = new Account(Name = 'Alpha Traders', Phone = '+91 98453 66666');
        Account b = new Account(Name = 'Bravo Traders', Phone = '+91 98453 77777');
        insert new List<Account>{ a, b };
        deliveredSale(a, 0.3, 50);   // ₹300
        deliveredSale(b, 0.5, 51);   // ₹500

        Test.startTest();
        // First payment: unique amount → matched, payer name remembered.
        AxisCreditAlertHandler.process(
            'INR 300.00 was credited to your A/c.',
            body('300.00', '500000000001', 'RAMESH K', 'Paym'));
        System.assertEquals('RAMESH K',
            [SELECT UPI_Payer_Name__c FROM Account WHERE Id = :a.Id].UPI_Payer_Name__c);
        System.assertEquals(null,
            [SELECT UPI_Payer_Name__c FROM Account WHERE Id = :b.Id].UPI_Payer_Name__c);

        // Both clients now owe ₹500 (a gets a second order), so amount is
        // ambiguous and the name is not in either account name — only the
        // learned payer name can tell them apart.
        deliveredSale(a, 0.5, 30);
        Bank_Credit_Alert__c second = AxisCreditAlertHandler.process(
            'INR 500.00 was credited to your A/c.',
            body('500.00', '500000000002', 'RAMESH K', 'Paym'));
        Test.stopTest();

        System.assertEquals('Matched', second.Status__c);
        System.assertEquals(a.Id, second.Client__c);
        System.assert(second.Match_Reason__c.contains('Known UPI payer'));
        System.assertEquals(500,
            [SELECT Balance_Due__c FROM Sale__c WHERE Client__c = :b.Id].Balance_Due__c);
    }

    @isTest
    static void testUnmatchedNeedsReviewWithTask() {
        Account a = new Account(Name = 'Alpha Traders', Phone = '+91 98453 44444');
        insert a;
        deliveredSale(a, 1.0, 50);

        Test.startTest();
        Bank_Credit_Alert__c alert = AxisCreditAlertHandler.process(
            'INR 777.00 was credited to your A/c.',
            body('777.00', '300000000001', 'RANDOM PERSON', 'UPI'));
        Test.stopTest();

        System.assertEquals('Needs Review', alert.Status__c);
        System.assertEquals(0, [SELECT COUNT() FROM Client_Payment__c]);
    }

    @isTest
    static void testHtmlOnlyBodyIsParsed() {
        Account a = new Account(Name = 'Beta Mart', Phone = '+91 98453 55555');
        insert a;
        Sale__c s = deliveredSale(a, 0.4, 50);   // ₹400
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'INR 400.00 was credited to your A/c.';
        email.htmlBody = '<div><p>Amount Credited:</p><p>INR 400.00</p>' +
            '<p>Date &amp; Time:</p><p>11-09-26, 17:25:31 IST</p>' +
            '<p>Transaction Info:</p><p>UPI/P2A/400000000001/BETA MART/SBI/UPI</p></div>';
        Test.startTest();
        new AxisCreditAlertHandler().handleInboundEmail(
            email, new Messaging.InboundEnvelope());
        Test.stopTest();
        Bank_Credit_Alert__c alert = [SELECT Status__c, Sale__c, UTR__c
                                      FROM Bank_Credit_Alert__c LIMIT 1];
        System.assertEquals('Matched', alert.Status__c);
        System.assertEquals(s.Id, alert.Sale__c);
        System.assertEquals('400000000001', alert.UTR__c);
    }

    @isTest
    static void testInboundEmailEntryPoint() {
        Messaging.InboundEmail email = new Messaging.InboundEmail();
        email.subject = 'Gmail Forwarding Confirmation';
        email.plainTextBody = 'Confirmation code: 123456';
        Messaging.InboundEmailResult r = new AxisCreditAlertHandler()
            .handleInboundEmail(email, new Messaging.InboundEnvelope());
        System.assertEquals(true, r.success);
        Bank_Credit_Alert__c logged = [SELECT Status__c, Raw_Body__c
                                       FROM Bank_Credit_Alert__c LIMIT 1];
        System.assertEquals('Not a Credit', logged.Status__c);
        System.assert(logged.Raw_Body__c.contains('123456'));
    }
}
