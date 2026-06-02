public with sharing class PersonFundsController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getFundsData() {

        List<Person_Fund__c> funds = [
            SELECT Id, Name, Total_Collected__c,
                   Total_Mfr_Paid__c, Total_Expenses__c,
                   Available_Funds__c, Last_Updated__c,
                   Opening_Balance_Date__c
            FROM Person_Fund__c
            ORDER BY Available_Funds__c DESC NULLS LAST
        ];

        List<Business_Summary__c> summaries = [
            SELECT Id, Total_Collected__c, Total_Mfr_Paid__c,
                   Total_Expenses__c, Available_Funds__c,
                   Last_Updated__c
            FROM Business_Summary__c
            WHERE Name = 'MAKHANA_SUMMARY'
            LIMIT 1
        ];

        List<Client_Payment__c> recentPayments = [
            SELECT Id, Amount__c, Payment_Date__c,
                   Mode_of_Payment__c, Accepted_By__c,
                   Sale__r.Name, Sale__r.Client__r.Name
            FROM Client_Payment__c
            ORDER BY Payment_Date__c DESC, CreatedDate DESC
            LIMIT 20
        ];

        List<Manufacturer_Payment__c> recentMfrPayments = [
            SELECT Id, Amount_Paid__c, Payment_Date__c,
                   Mode_of_Payment__c, Paid_By__c,
                   Purchase__r.Name,
                   Purchase__r.Supplier__r.Name
            FROM Manufacturer_Payment__c
            ORDER BY Payment_Date__c DESC, CreatedDate DESC
            LIMIT 20
        ];

        List<Expense__c> recentExpenses = [
            SELECT Id, Amount__c, Expense_Date__c,
                   Expense_Type__c, Spent_By__c,
                   Notes_Remarks__c 
            FROM Expense__c
            ORDER BY Expense_Date__c DESC, CreatedDate DESC
            LIMIT 20
        ];

        List<String> expenseTypes = new List<String>();
        for (Schema.PicklistEntry e :
            Expense__c.Expense_Type__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) expenseTypes.add(e.getValue());
        }

        List<String> teamMembers = new List<String>();
        for (Schema.PicklistEntry e :
            Expense__c.Spent_By__c.getDescribe()
                .getPicklistValues()) {
            if (e.isActive()) teamMembers.add(e.getValue());
        }

        // Compute opening balance per person
        // = Total_Collected__c minus actual Client_Payment records
        // Any positive difference = manually added opening balance
        Map<String, Decimal> actualCollected = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Accepted_By__c person, SUM(Amount__c) total
            FROM Client_Payment__c
            WHERE Accepted_By__c != null
            GROUP BY Accepted_By__c
        ]) {
            actualCollected.put(
                (String) ar.get('person'),
                (Decimal) ar.get('total')
            );
        }

        List<Map<String, Object>> openingBalances =
            new List<Map<String, Object>>();

        for (Person_Fund__c pf : funds) {
            Decimal recorded = pf.Total_Collected__c != null
                               ? pf.Total_Collected__c : 0;
            Decimal actual   = actualCollected.containsKey(pf.Name)
                               ? actualCollected.get(pf.Name) : 0;
            Decimal opening  = recorded - actual;

            if (opening > 0) {
                openingBalances.add(new Map<String, Object>{
                    'person'  => pf.Name,
                    'amount'  => opening,
                    'date'    => pf.Opening_Balance_Date__c != null
                                 ? String.valueOf(pf.Opening_Balance_Date__c).left(10)
                                 : pf.Last_Updated__c != null
                                 ? String.valueOf(pf.Last_Updated__c).left(10)
                                 : String.valueOf(Date.today()).left(10),
                    'label'   => 'Opening balance — previous stock'
                });
            }
        }

        return new Map<String, Object>{
            'funds'             => funds,
            'summary'           => summaries.isEmpty()
                                   ? null : summaries[0],
            'recentPayments'    => recentPayments,
            'recentMfrPayments' => recentMfrPayments,
            'recentExpenses'    => recentExpenses,
            'expenseTypes'      => expenseTypes,
            'teamMembers'       => teamMembers,
            'openingBalances'   => openingBalances
        };
    }

    @AuraEnabled
    public static void saveExpense(
        Decimal amount,
        String expenseDate,
        String expenseType,
        String spentBy,
        String description
    ) {
        insert new Expense__c(
            Amount__c       = amount,
            Expense_Date__c = Date.valueOf(expenseDate),
            Expense_Type__c = expenseType,
            Spent_By__c     = spentBy,
            Notes_Remarks__c  = String.isBlank(description)
                              ? null : description
        );
    }

    @AuraEnabled(cacheable=true)
    public static List<Expense__c> getExpensesForPerson(
        String personName
    ) {
        return [
            SELECT Id, Amount__c, Expense_Date__c,
                   Expense_Type__c, Spent_By__c,
                   Notes_Remarks__c
            FROM Expense__c
            WHERE Spent_By__c = :personName
            ORDER BY Expense_Date__c DESC
            LIMIT 50
        ];
    }
}