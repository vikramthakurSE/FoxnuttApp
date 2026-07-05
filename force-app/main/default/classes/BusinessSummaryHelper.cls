public class BusinessSummaryHelper {

    private static final String SUMMARY_NAME = 'MAKHANA_SUMMARY';

    // ── Core: update Business_Summary__c total fields ─────────────────
    public static void updateTotal(String fieldName, Decimal delta) {
        if (delta == 0) return;

        List<Business_Summary__c> summaries = [
            SELECT Id, Total_Collected__c, Total_Mfr_Paid__c,
                   Total_Expenses__c, Last_Updated__c
            FROM   Business_Summary__c
            WHERE  Name = :SUMMARY_NAME
            LIMIT  1
        ];
        if (summaries.isEmpty()) return;

        Business_Summary__c s = summaries[0];
        Decimal cur = (Decimal) s.get(fieldName);
        s.put(fieldName, (cur != null ? cur : 0) + delta);
        s.Last_Updated__c = DateTime.now();
        update s;
    }

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
        Decimal totalDelta = 0;

        if (newList != null) {
            Map<String, Decimal> d = buildDeltas(
                newList, 'Amount__c', 'Accepted_By__c', 1);
            deltas = mergeDeltas(deltas, d);
            for (Decimal v : d.values()) totalDelta += v;
        }
        if (oldList != null) {
            Map<String, Decimal> d = buildDeltas(
                oldList, 'Amount__c', 'Accepted_By__c', -1);
            deltas = mergeDeltas(deltas, d);
            for (Decimal v : d.values()) totalDelta += v;
        }

        updateTotal('Total_Collected__c', totalDelta);
        updatePersonFunds('Total_Collected__c', deltas);
    }

    // ── MANUFACTURER PAYMENT ──────────────────────────────────────────
    public static void onMfrPayment(
        List<Manufacturer_Payment__c> newList,
        List<Manufacturer_Payment__c> oldList
    ) {
        Map<String, Decimal> deltas = new Map<String, Decimal>();
        Decimal totalDelta = 0;

        if (newList != null) {
            Map<String, Decimal> d = buildDeltas(
                newList, 'Amount_Paid__c', 'Paid_By__c', 1);
            deltas = mergeDeltas(deltas, d);
            for (Decimal v : d.values()) totalDelta += v;
        }
        if (oldList != null) {
            Map<String, Decimal> d = buildDeltas(
                oldList, 'Amount_Paid__c', 'Paid_By__c', -1);
            deltas = mergeDeltas(deltas, d);
            for (Decimal v : d.values()) totalDelta += v;
        }

        updateTotal('Total_Mfr_Paid__c', totalDelta);
        updatePersonFunds('Total_Mfr_Paid__c', deltas);
    }

    // ── EXPENSE ───────────────────────────────────────────────────────
    public static void onExpense(
        List<Expense__c> newList,
        List<Expense__c> oldList
    ) {
        Map<String, Decimal> deltas = new Map<String, Decimal>();
        Decimal totalDelta = 0;

        if (newList != null) {
            Map<String, Decimal> d = buildDeltas(
                newList, 'Amount__c', 'Spent_By__c', 1);
            deltas = mergeDeltas(deltas, d);
            for (Decimal v : d.values()) totalDelta += v;
        }
        if (oldList != null) {
            Map<String, Decimal> d = buildDeltas(
                oldList, 'Amount__c', 'Spent_By__c', -1);
            deltas = mergeDeltas(deltas, d);
            for (Decimal v : d.values()) totalDelta += v;
        }

        updateTotal('Total_Expenses__c', totalDelta);
        updatePersonFunds('Total_Expenses__c', deltas);
    }
}