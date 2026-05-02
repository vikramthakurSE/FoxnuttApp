public with sharing class AccountsListController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAccounts(String searchTerm) {
        String likeSearch = '%' +
            (String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';

        List<Account> clients = [
            SELECT Id, Name, Phone, Area__c,
                   Regional_Manager__c, Contact_Person__c,
                   IsActive__c, GSTIN__c
            FROM Account
            WHERE RecordType.Name = 'Client'
            AND (Name LIKE :likeSearch
                 OR Area__c LIKE :likeSearch
                 OR Contact_Person__c LIKE :likeSearch)
            ORDER BY Name ASC
            LIMIT 100
        ];

        List<Account> suppliers = [
            SELECT Id, Name, Phone
            FROM Account
            WHERE RecordType.Name = 'Supplier'
            AND Name LIKE :likeSearch
            ORDER BY Name ASC
            LIMIT 20
        ];

        // ── Calculate client balances from Sales directly ──
        Set<Id> clientIds = new Set<Id>();
        for (Account c : clients) clientIds.add(c.Id);

        Map<Id, Decimal> clientBalances = new Map<Id, Decimal>();
        Map<Id, Integer> clientSaleCounts = new Map<Id, Integer>();

        if (!clientIds.isEmpty()) {
            // Real outstanding from Sale records — never stale
            for (AggregateResult ar : [
                SELECT Client__c,
                       SUM(Balance_Due__c) totalDue,
                       COUNT(Id) saleCount
                FROM Sale__c
                WHERE Client__c IN :clientIds
                GROUP BY Client__c
            ]) {
                Id cId = (Id) ar.get('Client__c');
                Decimal due = (Decimal) ar.get('totalDue');
                clientBalances.put(cId, due != null ? due : 0);
                clientSaleCounts.put(
                    cId,
                    Integer.valueOf(ar.get('saleCount'))
                );
            }
        }

        // ── Calculate supplier outstanding from Purchases ──
        Set<Id> supplierIds = new Set<Id>();
        for (Account s : suppliers) supplierIds.add(s.Id);

        Map<Id, Decimal> supplierOutstanding = new Map<Id, Decimal>();
        Map<Id, Integer> supplierPurchaseCounts = new Map<Id, Integer>();

        if (!supplierIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Supplier__c,
                       SUM(Amount_Outstanding__c) outstanding,
                       COUNT(Id) purchaseCount
                FROM Purchase__c
                WHERE Supplier__c IN :supplierIds
                GROUP BY Supplier__c
            ]) {
                Id sId = (Id) ar.get('Supplier__c');
                Decimal out = (Decimal) ar.get('outstanding');
                supplierOutstanding.put(sId, out != null ? out : 0);
                supplierPurchaseCounts.put(
                    sId,
                    Integer.valueOf(ar.get('purchaseCount'))
                );
            }
        }

        // ── Build client response ──
        List<Map<String, Object>> clientData =
            new List<Map<String, Object>>();
        for (Account c : clients) {
            Decimal bal = clientBalances.containsKey(c.Id)
                ? clientBalances.get(c.Id) : 0;
            Map<String, Object> row = new Map<String, Object>();
            row.put('id',        c.Id);
            row.put('name',      c.Name);
            row.put('phone',     c.Phone);
            row.put('area',      c.Area__c);
            row.put('manager',   c.Regional_Manager__c);
            row.put('contact',   c.Contact_Person__c);
            row.put('balance',   bal);
            row.put('isActive',  c.IsActive__c);
            row.put('gstin',     c.GSTIN__c);
            row.put('saleCount', clientSaleCounts.containsKey(c.Id)
                ? clientSaleCounts.get(c.Id) : 0);
            clientData.add(row);
        }

        // Sort by balance descending in Apex
        clientData.sort(new BalanceComparator());

        // ── Build supplier response ──
        List<Map<String, Object>> supplierData =
            new List<Map<String, Object>>();
        for (Account s : suppliers) {
            Decimal out = supplierOutstanding.containsKey(s.Id)
                ? supplierOutstanding.get(s.Id) : 0;
            Map<String, Object> row = new Map<String, Object>();
            row.put('id',          s.Id);
            row.put('name',        s.Name);
            row.put('phone',       s.Phone);
            row.put('outstanding', out);
            row.put('purchases',   supplierPurchaseCounts.containsKey(s.Id)
                ? supplierPurchaseCounts.get(s.Id) : 0);
            supplierData.add(row);
        }

        return new Map<String, Object>{
            'clients'   => clientData,
            'suppliers' => supplierData
        };
    }

    // Comparator to sort clients by balance descending
    private class BalanceComparator
        implements Comparator<Map<String, Object>> {
        public Integer compare(
            Map<String, Object> a,
            Map<String, Object> b
        ) {
            Decimal balA = (Decimal) a.get('balance');
            Decimal balB = (Decimal) b.get('balance');
            if (balA == null) balA = 0;
            if (balB == null) balB = 0;
            if (balA > balB) return -1;
            if (balA < balB) return 1;
            return 0;
        }
    }
}