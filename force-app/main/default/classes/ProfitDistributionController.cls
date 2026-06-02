public class ProfitDistributionController {

    private static final Decimal VIKRAM_SHARE  = 0.45;
    private static final Decimal ROHAN_SHARE   = 0.45;
    private static final Decimal COMPANY_SHARE = 0.10;

    // ── Get available quarters for selector ───────────────────────────────
    @AuraEnabled(cacheable=true)
    public static List<String> getAvailableQuarters() {
        Set<String> quarters = new Set<String>();

        for (AggregateResult ar : [
            SELECT Quarter__c q FROM Sale__c
            WHERE Quarter__c != null
            GROUP BY Quarter__c
            ORDER BY Quarter__c DESC
        ]) {
            quarters.add((String) ar.get('q'));
        }

        // Add current quarter in case no sales yet
        quarters.add(currentQuarter());

        List<String> sorted = new List<String>(quarters);
        sorted.sort();
        // Reverse for newest first
        List<String> result = new List<String>();
        for (Integer i = sorted.size() - 1; i >= 0; i--) {
            result.add(sorted[i]);
        }
        return result;
    }

    // ── Calculate profit for a quarter ────────────────────────────────────
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getQuarterlyProfit(String quarter) {
        // Revenue + Profit from delivered sales
        Decimal revenue = 0;
        Decimal profit  = 0;
        for (AggregateResult ar : [
            SELECT SUM(Total_Revenue__c) rev,
                   SUM(Total_Profit__c) pft
            FROM Sale__c
            WHERE Quarter__c = :quarter
            AND Order_Status__c = 'Delivered'
        ]) {
            revenue = ar.get('rev') != null ? (Decimal) ar.get('rev') : 0;
            profit  = ar.get('pft') != null ? (Decimal) ar.get('pft') : 0;
        }

        // Expenses in the quarter date range
        Date qStart = quarterStart(quarter);
        Date qEnd   = qStart.addMonths(3).addDays(-1);
        Decimal expenses = 0;
        for (AggregateResult ar : [
            SELECT SUM(Amount__c) total
            FROM Expense__c
            WHERE Expense_Date__c >= :qStart
            AND   Expense_Date__c <= :qEnd
        ]) {
            expenses = ar.get('total') != null
                       ? (Decimal) ar.get('total') : 0;
        }

        // Net profit = gross margin - expenses
        Decimal netProfit = profit - expenses;

        // Check if already distributed this quarter
        List<Profit_Withdrawal__c> existing = [
            SELECT Id, Adjusted_Profit__c,
                   Vikram_Amount__c, Rohan_Amount__c,
                   Company_Reserve__c, Withdrawal_Date__c,
                   Notes__c
            FROM Profit_Withdrawal__c
            WHERE Quarter__c = :quarter
            LIMIT 1
        ];

        Boolean alreadyDistributed = !existing.isEmpty();
        Map<String, Object> result = new Map<String, Object>{
            'quarter'            => quarter,
            'revenue'            => revenue,
            'grossMargin'        => profit,
            'expenses'           => expenses,
            'netProfit'          => netProfit,
            'vikramShare'        => (netProfit * VIKRAM_SHARE).setScale(2),
            'rohanShare'         => (netProfit * ROHAN_SHARE).setScale(2),
            'companyShare'       => (netProfit * COMPANY_SHARE).setScale(2),
            'alreadyDistributed' => alreadyDistributed
        };

        if (alreadyDistributed) {
            Profit_Withdrawal__c pw = existing[0];
            result.put('existingId',           pw.Id);
            result.put('existingAdjusted',     pw.Adjusted_Profit__c);
            result.put('existingVikram',       pw.Vikram_Amount__c);
            result.put('existingRohan',        pw.Rohan_Amount__c);
            result.put('existingCompany',      pw.Company_Reserve__c);
            result.put('existingDate',
                String.valueOf(pw.Withdrawal_Date__c));
            result.put('existingNotes',        pw.Notes__c);
        }

        return result;
    }

    // ── Execute profit distribution ────────────────────────────────────────
    @AuraEnabled
    public static Map<String, Object> executeDistribution(
        String quarter,
        Decimal adjustedProfit,
        String withdrawalDate,
        String notes
    ) {
        if (adjustedProfit == null || adjustedProfit <= 0) {
            throw new AuraHandledException(
                'Profit amount must be greater than 0.'
            );
        }

        Decimal vikramAmt  = (adjustedProfit * VIKRAM_SHARE) .setScale(2);
        Decimal rohanAmt   = (adjustedProfit * ROHAN_SHARE)  .setScale(2);
        Decimal companyAmt = (adjustedProfit * COMPANY_SHARE).setScale(2);
        Date    wDate      = Date.valueOf(withdrawalDate);

        Savepoint sp = Database.setSavepoint();
        try {
            // Create withdrawal record
            Profit_Withdrawal__c pw = new Profit_Withdrawal__c(
                Quarter__c          = quarter,
                Withdrawal_Date__c  = wDate,
                Adjusted_Profit__c  = adjustedProfit,
                Vikram_Amount__c    = vikramAmt,
                Rohan_Amount__c     = rohanAmt,
                Company_Reserve__c  = companyAmt,
                Notes__c            = notes
            );
            insert pw;

            // Deduct from each person's Total_Withdrawn__c
            Map<String, Person_Fund__c> fundMap =
                new Map<String, Person_Fund__c>();
            for (Person_Fund__c pf : [
                SELECT Id, Name, Total_Withdrawn__c
                FROM Person_Fund__c
                WHERE Name IN ('Vikram', 'Rohan')
            ]) {
                fundMap.put(pf.Name, pf);
            }

            List<Person_Fund__c> toUpdate =
                new List<Person_Fund__c>();

            if (fundMap.containsKey('Vikram')) {
                Person_Fund__c vf = fundMap.get('Vikram');
                vf.Total_Withdrawn__c =
                    (vf.Total_Withdrawn__c != null
                     ? vf.Total_Withdrawn__c : 0) + vikramAmt;
                vf.Last_Updated__c = Date.today();
                toUpdate.add(vf);
            }
            if (fundMap.containsKey('Rohan')) {
                Person_Fund__c rf = fundMap.get('Rohan');
                rf.Total_Withdrawn__c =
                    (rf.Total_Withdrawn__c != null
                     ? rf.Total_Withdrawn__c : 0) + rohanAmt;
                rf.Last_Updated__c = Date.today();
                toUpdate.add(rf);
            }

            if (!toUpdate.isEmpty()) update toUpdate;

            return new Map<String, Object>{
                'success'     => true,
                'vikramAmt'   => vikramAmt,
                'rohanAmt'    => rohanAmt,
                'companyAmt'  => companyAmt,
                'withdrawalId'=> pw.Id
            };

        } catch (Exception e) {
            Database.rollback(sp);
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Get withdrawal history ────────────────────────────────────────────
    @AuraEnabled(cacheable=false)
    public static List<Profit_Withdrawal__c> getWithdrawalHistory() {
        return [
            SELECT Id, Name, Quarter__c, Withdrawal_Date__c,
                   Adjusted_Profit__c, Vikram_Amount__c,
                   Rohan_Amount__c, Company_Reserve__c,
                   Notes__c
            FROM Profit_Withdrawal__c
            ORDER BY Withdrawal_Date__c DESC
            LIMIT 10
        ];
    }

    // ── Helpers ───────────────────────────────────────────────────────────
    private static String currentQuarter() {
        Date today = Date.today();
        Integer q  = (Integer) Math.ceil(today.month() / 3.0);
        return 'Qtr' + q + '_' + today.year();
    }

    private static Date quarterStart(String quarter) {
        List<String> parts = quarter.split('_');
        Integer qNum = Integer.valueOf(parts[0].replace('Qtr', ''));
        Integer yr   = Integer.valueOf(parts[1]);
        Integer startMonth = (qNum - 1) * 3 + 1;
        return Date.newInstance(yr, startMonth, 1);
    }
}