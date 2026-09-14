public class BusinessSummaryHelper {

    private static final String SUMMARY_NAME = 'MAKHANA_SUMMARY';

    // ── Core: rebuild Business_Summary__c from Person_Fund__c ─────────
    // The summary is the team total of the person ledgers. It used to keep
    // its own running deltas, which never saw opening balances, transfers
    // or withdrawals (those only touch Person_Fund__c), so it drifted tens
    // of thousands of rupees away. Recomputing from the ledgers on every
    // Person_Fund__c change (PersonFundSummaryTrigger) keeps them equal.
    public static void syncFromPersonFunds() {
        AggregateResult ar = [
            SELECT SUM(Total_Collected__c) collected,
                   SUM(Total_Mfr_Paid__c)  mfrPaid,
                   SUM(Total_Expenses__c)  expenses,
                   SUM(Total_Withdrawn__c) withdrawn
            FROM   Person_Fund__c
        ];

        List<Business_Summary__c> summaries = [
            SELECT Id FROM Business_Summary__c
            WHERE  Name = :SUMMARY_NAME
            LIMIT  1
        ];
        Business_Summary__c s = summaries.isEmpty()
            ? new Business_Summary__c(Name = SUMMARY_NAME)
            : summaries[0];

        s.Total_Collected__c = nz((Decimal) ar.get('collected'));
        s.Total_Mfr_Paid__c  = nz((Decimal) ar.get('mfrPaid'));
        s.Total_Expenses__c  = nz((Decimal) ar.get('expenses'));
        s.Total_Withdrawn__c = nz((Decimal) ar.get('withdrawn'));
        s.Last_Updated__c    = DateTime.now();
        upsert s;
    }

    private static Decimal nz(Decimal d) { return d != null ? d : 0; }

    // ── Core: update Person_Fund__c records dynamically ───────────────
    // personDeltas: Map of person name → delta amount (+ or -)
    public static void updatePersonFunds(
        String fieldName,
        Map<String, Decimal> personDeltas
    ) {
        if (personDeltas.isEmpty()) return;

        // Remove zero deltas
        Map<String, Decimal> cleaned = new Map<String, Decimal>();
        for (String name : personDeltas.keySet()) {
            if (personDeltas.get(name) != 0) {
                cleaned.put(name, personDeltas.get(name));
            }
        }
        if (cleaned.isEmpty()) return;

        // Query only the Person_Fund__c records we need
        List<Person_Fund__c> funds = [
            SELECT Id, Name, Total_Collected__c,
                   Total_Mfr_Paid__c, Total_Expenses__c, Last_Updated__c
            FROM   Person_Fund__c
            WHERE  Name IN :cleaned.keySet()
        ];

        List<Person_Fund__c> toUpdate = new List<Person_Fund__c>();

        for (Person_Fund__c pf : funds) {
            Decimal delta = cleaned.get(pf.Name);
            if (delta == null || delta == 0) continue;

            Decimal cur = (Decimal) pf.get(fieldName);
            pf.put(fieldName, (cur != null ? cur : 0) + delta);
            pf.Last_Updated__c = DateTime.now();
            toUpdate.add(pf);
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // ── Build person delta map from a list of records ─────────────────
    // Works for insert/undelete (sign = +1) and delete (sign = -1)
    private static Map<String, Decimal> buildDeltas(
        List<SObject> records,
        String amountField,
        String personField,
        Integer sign
    ) {
        Map<String, Decimal> deltas = new Map<String, Decimal>();
        for (SObject rec : records) {
            Decimal amt    = (Decimal) rec.get(amountField);
            String  person = (String)  rec.get(personField);
            if (amt == null || amt == 0) continue;
            if (String.isBlank(person)) person = 'Self'; // fallback
            Decimal existing = deltas.containsKey(person)
                               ? deltas.get(person) : 0;
            deltas.put(person, existing + (amt * sign));
        }
        return deltas;
    }

    // ── Merge two delta maps ──────────────────────────────────────────
    private static Map<String, Decimal> mergeDeltas(
        Map<String, Decimal> a,
        Map<String, Decimal> b
    ) {
        Map<String, Decimal> result = new Map<String, Decimal>(a);
        for (String key : b.keySet()) {
            Decimal existing = result.containsKey(key) ? result.get(key) : 0;
            result.put(key, existing + b.get(key));
        }
        return result;
    }

    // ── CLIENT PAYMENT ────────────────────────────────────────────────
    public static void onClientPayment(
        List<Client_Payment__c> newList,
        List<Client_Payment__c> oldList
    ) {
        Map<String, Decimal> deltas = new Map<String, Decimal>();

        if (newList != null) {
            Map<String, Decimal> d = buildDeltas(
                newList, 'Amount__c', 'Accepted_By__c', 1);
            deltas = mergeDeltas(deltas, d);
        }
        if (oldList != null) {
            Map<String, Decimal> d = buildDeltas(
                oldList, 'Amount__c', 'Accepted_By__c', -1);
            deltas = mergeDeltas(deltas, d);
        }

        updatePersonFunds('Total_Collected__c', deltas);
    }

    // ── MANUFACTURER PAYMENT ──────────────────────────────────────────
    public static void onMfrPayment(
        List<Manufacturer_Payment__c> newList,
        List<Manufacturer_Payment__c> oldList
    ) {
        Map<String, Decimal> deltas = new Map<String, Decimal>();

        if (newList != null) {
            Map<String, Decimal> d = buildDeltas(
                newList, 'Amount_Paid__c', 'Paid_By__c', 1);
            deltas = mergeDeltas(deltas, d);
        }
        if (oldList != null) {
            Map<String, Decimal> d = buildDeltas(
                oldList, 'Amount_Paid__c', 'Paid_By__c', -1);
            deltas = mergeDeltas(deltas, d);
        }

        updatePersonFunds('Total_Mfr_Paid__c', deltas);
    }

    // ── EXPENSE ───────────────────────────────────────────────────────
    public static void onExpense(
        List<Expense__c> newList,
        List<Expense__c> oldList
    ) {
        Map<String, Decimal> deltas = new Map<String, Decimal>();

        if (newList != null) {
            Map<String, Decimal> d = buildDeltas(
                newList, 'Amount__c', 'Spent_By__c', 1);
            deltas = mergeDeltas(deltas, d);
        }
        if (oldList != null) {
            Map<String, Decimal> d = buildDeltas(
                oldList, 'Amount__c', 'Spent_By__c', -1);
            deltas = mergeDeltas(deltas, d);
        }

        updatePersonFunds('Total_Expenses__c', deltas);
    }
}