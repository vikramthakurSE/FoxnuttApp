@isTest
private class BusinessSummaryHelperTest {

    @isTest
    static void summaryFollowsPersonFundLedgers() {
        insert new Business_Summary__c(Name = 'MAKHANA_SUMMARY');
        Person_Fund__c v = new Person_Fund__c(Name = 'Vikram',
            Total_Collected__c = 1000.50, Total_Mfr_Paid__c = 200,
            Total_Expenses__c = 50);
        Person_Fund__c r = new Person_Fund__c(Name = 'Rohan',
            Total_Collected__c = 500, Total_Mfr_Paid__c = 100,
            Total_Expenses__c = 25);
        insert new List<Person_Fund__c>{ v, r };

        Test.startTest();
        // A manual adjustment and a withdrawal — neither goes through a
        // payment/expense trigger, which is what used to leave the summary behind
        v.Total_Collected__c = 1500.50;
        r.Total_Withdrawn__c = 75;
        update new List<Person_Fund__c>{ v, r };

        insert new Expense__c(Amount__c = 10, Expense_Date__c = Date.today(),
            Expense_Type__c = Expense__c.Expense_Type__c.getDescribe()
                .getPicklistValues()[0].getValue(),
            Spent_By__c = 'Vikram');
        Test.stopTest();

        Business_Summary__c s = [SELECT Total_Collected__c, Total_Mfr_Paid__c,
            Total_Expenses__c, Total_Withdrawn__c, Available_Funds__c
            FROM Business_Summary__c WHERE Name = 'MAKHANA_SUMMARY'];
        System.assertEquals(2000.50, s.Total_Collected__c);
        System.assertEquals(300,     s.Total_Mfr_Paid__c);
        System.assertEquals(85,      s.Total_Expenses__c);
        System.assertEquals(75,      s.Total_Withdrawn__c);
        System.assertEquals(1540.50, s.Available_Funds__c);
    }

    @isTest
    static void createsSummaryWhenMissing() {
        insert new Person_Fund__c(Name = 'Vikram', Total_Collected__c = 10);
        System.assertEquals(10, [SELECT Total_Collected__c FROM Business_Summary__c
            WHERE Name = 'MAKHANA_SUMMARY'].Total_Collected__c);
    }
}
