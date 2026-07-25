public with sharing class PersonFundsController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getFundsData() {

        List<Person_Fund__c> funds = [
            SELECT Id, Name, Total_Collected__c,
                   Total_Mfr_Paid__c, Total_Expenses__c,
                   Available_Funds__c, Last_Updated__c,
                   Opening_Balance_Date__c, Adjustment_Log__c
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

        // Parse adjustment logs per person
        List<Map<String, Object>> adjustmentEntries =
            new List<Map<String, Object>>();

        for (Person_Fund__c pf : funds) {
            Decimal recorded = pf.Total_Collected__c != null
                               ? pf.Total_Collected__c : 0;
            Decimal actual   = actualCollected.containsKey(pf.Name)
                               ? actualCollected.get(pf.Name) : 0;

            // Parse Adjustment_Log__c to extract logged adjustments
            Decimal totalAdjusted = 0;
            if (String.isNotBlank(pf.Adjustment_Log__c)) {
                try {
                    List<Object> logEntries =
                        (List<Object>) JSON.deserializeUntyped(
                            pf.Adjustment_Log__c
                        );
                    for (Object entry : logEntries) {
                        Map<String, Object> e =
                            (Map<String, Object>) entry;
                        Decimal amt  = e.get('amount') != null
                            ? Decimal.valueOf(String.valueOf(e.get('amount'))) : 0;
                        String  type = (String) e.get('type');
                        String  dateStr = (String) e.get('date');
                        String  rsn  = (String) e.get('reason');
                        if (type == 'Addition') totalAdjusted += amt;
                        else totalAdjusted -= amt;

                        adjustmentEntries.add(new Map<String, Object>{
                            'person' => pf.Name,
                            'amount' => amt,
                            'type'   => type,
                            'date'   => dateStr != null
                                        ? dateStr.left(10) : '',
                            'reason' => rsn
                        });
                    }
                } catch (Exception ex) {
                    System.debug('Log parse error: ' + ex.getMessage());
                }
            }

            // Opening balance = recorded - actual payments - logged adjustments
            Decimal opening = recorded - actual - Math.abs(totalAdjusted);

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
            'openingBalances'   => openingBalances,
            'adjustmentEntries' => adjustmentEntries
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

    // ── Balance Adjustment (with transfer + profit withdrawal support) ─────
    // Reason options:
    //   'Transferred to Vikram'  → deduct from person, add to Vikram
    //   'Transferred to Rohan'   → deduct from person, add to Rohan
    //   'Profit Withdrawal'      → deduct from person (goes to Total_Withdrawn__c)
    //   'Balance Adjustment'     → add or subtract via adjustmentType
    @AuraEnabled
    public static void adjustBalance(
        String personName,
        Decimal amount,
        String adjustmentType,
        String reason
    ) {
        if (amount == null || amount <= 0) {
            throw new AuraHandledException('Amount must be greater than 0.');
        }

        List<Person_Fund__c> funds = [
            SELECT Id, Name, Total_Collected__c,
                   Last_Updated__c, Adjustment_Log__c
            FROM Person_Fund__c
            WHERE Name = :personName
            LIMIT 1
        ];

        if (funds.isEmpty()) {
            throw new AuraHandledException(
                'Person Fund record not found for: ' + personName
            );
        }

        Person_Fund__c pf = funds[0];

        // Step 1: Write the log entry FIRST in its own DML
        // This ensures it persists even if a trigger fires
        // on the balance update below
        String today    = String.valueOf(Date.today()).left(10);
        String newEntry = '{"date":"' + today +
                          '","amount":' + amount.setScale(2) +
                          ',"type":"' + adjustmentType +
                          '","reason":"' + reason.replaceAll('"', '\'') +
                          '"}';

        String existing = pf.Adjustment_Log__c;
        String newLog   = String.isBlank(existing)
                          ? '[' + newEntry + ']'
                          : existing.removeEnd(']') + ',' + newEntry + ']';

        update new Person_Fund__c(
            Id                 = pf.Id,
            Adjustment_Log__c  = newLog
        );

        // Step 2: Update balance separately
        Decimal current = pf.Total_Collected__c != null
                          ? pf.Total_Collected__c : 0;
        Decimal updated = adjustmentType == 'Addition'
                          ? current + amount
                          : current - amount;

        update new Person_Fund__c(
            Id                 = pf.Id,
            Total_Collected__c = updated,
            Last_Updated__c    = Date.today()
        );
    }

    // ── Get available quarters ────────────────────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<String> getAvailableQuarters() {
        Set<String> quarters = new Set<String>();

        // From client payments — bucketed by the related Sale's date, not the
        // payment date, so cash collected late still counts in the quarter the
        // sale was made (mirrors the manufacturer-payment rule below)
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(Sale__r.Sale_Date__c) yr,
                   CALENDAR_MONTH(Sale__r.Sale_Date__c) mo
            FROM Client_Payment__c
            WHERE Sale__r.Sale_Date__c != null
            GROUP BY CALENDAR_YEAR(Sale__r.Sale_Date__c),
                     CALENDAR_MONTH(Sale__r.Sale_Date__c)
        ]) {
            Integer yr = (Integer) ar.get('yr');
            Integer mo = (Integer) ar.get('mo');
            Integer q  = (Integer) Math.ceil(mo / 3.0);
            quarters.add('Qtr' + q + '_' + yr);
        }

        // From mfr payments — bucketed by the related Purchase's order date,
        // not the payment date, so a late payment still counts in the
        // quarter the order was placed
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(Purchase__r.Order_Date__c) yr,
                   CALENDAR_MONTH(Purchase__r.Order_Date__c) mo
            FROM Manufacturer_Payment__c
            WHERE Purchase__r.Order_Date__c != null
            GROUP BY CALENDAR_YEAR(Purchase__r.Order_Date__c),
                     CALENDAR_MONTH(Purchase__r.Order_Date__c)
        ]) {
            Integer yr = (Integer) ar.get('yr');
            Integer mo = (Integer) ar.get('mo');
            Integer q  = (Integer) Math.ceil(mo / 3.0);
            quarters.add('Qtr' + q + '_' + yr);
        }

        // From expenses
        for (AggregateResult ar : [
            SELECT CALENDAR_YEAR(Expense_Date__c) yr,
                   CALENDAR_MONTH(Expense_Date__c) mo
            FROM Expense__c
            WHERE Expense_Date__c != null
            GROUP BY CALENDAR_YEAR(Expense_Date__c),
                     CALENDAR_MONTH(Expense_Date__c)
        ]) {
            Integer yr = (Integer) ar.get('yr');
            Integer mo = (Integer) ar.get('mo');
            Integer q  = (Integer) Math.ceil(mo / 3.0);
            quarters.add('Qtr' + q + '_' + yr);
        }

        // Add current quarter
        Date today = Date.today();
        Integer curQ = (Integer) Math.ceil(today.month() / 3.0);
        quarters.add('Qtr' + curQ + '_' + today.year());

        // Sort newest first by (year, quarter). A plain string sort ordered
        // "Qtr4_2025" ahead of "Qtr3_2026" because it compared the quarter
        // digit before the year — so sort on a numeric key year*10+quarter.
        Map<Integer, String> keyToLabel = new Map<Integer, String>();
        List<Integer> keys = new List<Integer>();
        for (String qs : quarters) {
            List<String> p = qs.split('_');
            Integer q   = Integer.valueOf(p[0].replace('Qtr', ''));
            Integer y   = Integer.valueOf(p[1]);
            Integer key = y * 10 + q;
            keyToLabel.put(key, qs);
            keys.add(key);
        }
        keys.sort();
        List<String> result = new List<String>();
        for (Integer i = keys.size() - 1; i >= 0; i--) {
            result.add(keyToLabel.get(keys[i]));
        }
        return result;
    }

    // ── Quarterly funds data ───────────────────────────────────────────────
    // Returns per-person collected/paid/expenses for the selected quarter
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getQuarterlyFundsData(
        String quarter
    ) {
        // Parse quarter → date range
        List<String> parts = quarter.split('_');
        Integer qNum       = Integer.valueOf(parts[0].replace('Qtr',''));
        Integer yr         = Integer.valueOf(parts[1]);
        Integer startMonth = (qNum - 1) * 3 + 1;
        Date qStart = Date.newInstance(yr, startMonth, 1);
        Date qEnd   = qStart.addMonths(3).addDays(-1);

        // Per-person collected — attributed to the quarter the SALE was made
        // (Sale__r.Sale_Date__c), not when the cash arrived, so a payment
        // collected late still counts toward the quarter that earned it
        Map<String, Decimal> collected = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Accepted_By__c person, SUM(Amount__c) total
            FROM Client_Payment__c
            WHERE Accepted_By__c != null
            AND Sale__r.Sale_Date__c >= :qStart
            AND Sale__r.Sale_Date__c <= :qEnd
            GROUP BY Accepted_By__c
        ]) {
            Decimal amt = (Decimal) ar.get('total');
            collected.put(
                (String) ar.get('person'),
                amt != null ? amt : 0
            );
        }

        // Per-person mfr paid — attributed to the quarter the PURCHASE was
        // placed (Purchase__r.Order_Date__c), not when the payment was made,
        // so a payment settled late doesn't distort the quarter it's paid in
        Map<String, Decimal> mfrPaid = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Paid_By__c person, SUM(Amount_Paid__c) total
            FROM Manufacturer_Payment__c
            WHERE Paid_By__c != null
            AND Purchase__r.Order_Date__c >= :qStart
            AND Purchase__r.Order_Date__c <= :qEnd
            GROUP BY Paid_By__c
        ]) {
            Decimal amt = (Decimal) ar.get('total');
            mfrPaid.put(
                (String) ar.get('person'),
                amt != null ? amt : 0
            );
        }

        // Per-person expenses
        Map<String, Decimal> expenses = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Spent_By__c person, SUM(Amount__c) total
            FROM Expense__c
            WHERE Spent_By__c != null
            AND Expense_Date__c >= :qStart
            AND Expense_Date__c <= :qEnd
            GROUP BY Spent_By__c
        ]) {
            Decimal amt = (Decimal) ar.get('total');
            expenses.put(
                (String) ar.get('person'),
                amt != null ? amt : 0
            );
        }

        // Team totals
        Decimal teamCollected = 0;
        Decimal teamMfrPaid   = 0;
        Decimal teamExpenses  = 0;
        for (Decimal v : collected.values()) teamCollected += v;
        for (Decimal v : mfrPaid.values())   teamMfrPaid   += v;
        for (Decimal v : expenses.values())  teamExpenses  += v;

        // Recent transactions for this quarter — client payments listed under
        // the quarter of their sale (same rule as the collected total above)
        List<Client_Payment__c> recentPayments = [
            SELECT Id, Amount__c, Payment_Date__c,
                   Mode_of_Payment__c, Accepted_By__c,
                   Sale__r.Name, Sale__r.Client__r.Name
            FROM Client_Payment__c
            WHERE Sale__r.Sale_Date__c >= :qStart
            AND Sale__r.Sale_Date__c <= :qEnd
            ORDER BY Payment_Date__c DESC
            LIMIT 50
        ];

        List<Manufacturer_Payment__c> recentMfrPayments = [
            SELECT Id, Amount_Paid__c, Payment_Date__c,
                   Mode_of_Payment__c, Paid_By__c,
                   Purchase__r.Name, Purchase__r.Order_Date__c,
                   Purchase__r.Supplier__r.Name
            FROM Manufacturer_Payment__c
            WHERE Purchase__r.Order_Date__c >= :qStart
            AND Purchase__r.Order_Date__c <= :qEnd
            ORDER BY Payment_Date__c DESC
            LIMIT 50
        ];

        List<Expense__c> recentExpenses = [
            SELECT Id, Amount__c, Expense_Date__c,
                   Expense_Type__c, Spent_By__c,
                   Notes_Remarks__c
            FROM Expense__c
            WHERE Expense_Date__c >= :qStart
            AND Expense_Date__c <= :qEnd
            ORDER BY Expense_Date__c DESC
            LIMIT 50
        ];

        // Build person summaries
        Set<String> allPersons = new Set<String>();
        allPersons.addAll(collected.keySet());
        allPersons.addAll(mfrPaid.keySet());
        allPersons.addAll(expenses.keySet());

        List<Map<String, Object>> personSummaries =
            new List<Map<String, Object>>();
        for (String person : allPersons) {
            Decimal c = collected.containsKey(person)
                ? collected.get(person) : 0;
            Decimal m = mfrPaid.containsKey(person)
                ? mfrPaid.get(person) : 0;
            Decimal e = expenses.containsKey(person)
                ? expenses.get(person) : 0;
            Decimal net = c - m - e;
            personSummaries.add(new Map<String, Object>{
                'name'       => person,
                'collected'  => c,
                'mfrPaid'    => m,
                'expenses'   => e,
                'netFlow'    => net
            });
        }

        return new Map<String, Object>{
            'quarter'          => quarter,
            'qStart'           => String.valueOf(qStart),
            'qEnd'             => String.valueOf(qEnd),
            'teamCollected'    => teamCollected,
            'teamMfrPaid'      => teamMfrPaid,
            'teamExpenses'     => teamExpenses,
            'teamNetFlow'      => teamCollected - teamMfrPaid - teamExpenses,
            'personSummaries'  => personSummaries,
            'recentPayments'   => recentPayments,
            'recentMfrPayments'=> recentMfrPayments,
            'recentExpenses'   => recentExpenses
        };
    }
}