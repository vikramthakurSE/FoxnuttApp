public with sharing class AccountsListController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getAccounts(String searchTerm) {
        String likeSearch = '%' +
            (String.isBlank(searchTerm) ? '' : searchTerm.trim()) + '%';

        // ── Clients ────────────────────────────────────────
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

        Set<Id> clientIds = new Set<Id>();
        for (Account c : clients) clientIds.add(c.Id);

        // Live balance from delivered sales
        Map<Id, Decimal> clientBalances   = new Map<Id, Decimal>();
        Map<Id, Integer> clientSaleCounts = new Map<Id, Integer>();

        if (!clientIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Client__c,
                       SUM(Balance_Due__c) totalDue,
                       COUNT(Id) saleCount
                FROM Sale__c
                WHERE Client__c IN :clientIds
                AND Order_Status__c = 'Delivered'
                GROUP BY Client__c
            ]) {
                Id cId = (Id) ar.get('Client__c');
                Decimal due = (Decimal) ar.get('totalDue');
                clientBalances.put(cId, due != null ? due : 0);
                clientSaleCounts.put(
                    cId, Integer.valueOf(ar.get('saleCount'))
                );
            }
        }

        // Active orders (Confirmed / Out for Delivery) per client
        Map<Id, Integer> confirmedMap     = new Map<Id, Integer>();
        Map<Id, Integer> outForDeliveryMap = new Map<Id, Integer>();

        if (!clientIds.isEmpty()) {
            for (AggregateResult ar : [
                SELECT Client__c, Order_Status__c,
                       COUNT(Id) cnt
                FROM Sale__c
                WHERE Client__c IN :clientIds
                AND Order_Status__c IN ('Confirmed', 'Out for Delivery')
                GROUP BY Client__c, Order_Status__c
            ]) {
                Id cId   = (Id)     ar.get('Client__c');
                String s = (String) ar.get('Order_Status__c');
                Integer cnt = Integer.valueOf(ar.get('cnt'));
                if (s == 'Confirmed') {
                    confirmedMap.put(cId, cnt);
                } else if (s == 'Out for Delivery') {
                    outForDeliveryMap.put(cId, cnt);
                }
            }
        }

        // Build client rows
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
            row.put('confirmedCount',
                confirmedMap.containsKey(c.Id)
                ? confirmedMap.get(c.Id) : 0);
            row.put('outForDeliveryCount',
                outForDeliveryMap.containsKey(c.Id)
                ? outForDeliveryMap.get(c.Id) : 0);
            clientData.add(row);
        }

        // Sort by live balance descending
        clientData.sort(new BalanceComparator());

        // ── Suppliers ──────────────────────────────────────
        List<Account> suppliers = [
            SELECT Id, Name, Phone
            FROM Account
            WHERE RecordType.Name = 'Supplier'
            AND Name LIKE :likeSearch
            ORDER BY Name ASC
            LIMIT 20
        ];

        Set<Id> supplierIds = new Set<Id>();
        for (Account s : suppliers) supplierIds.add(s.Id);

        Map<Id, Decimal> supplierOutstanding  = new Map<Id, Decimal>();
        Map<Id, Integer> supplierPurchaseCounts = new Map<Id, Integer>();

        if (!supplierIds.isEmpty()) {
            // Amount_Outstanding__c formula excludes tax.
            // Compute true outstanding = Total_Order_Cost + Tax - Total_Paid
            for (AggregateResult ar : [
                SELECT Supplier__c,
                       SUM(Total_Order_Cost__c) totalCost,
                       SUM(Tax_Amount__c)       totalTax,
                       SUM(Total_Paid__c)       totalPaid,
                       COUNT(Id)                purchaseCount
                FROM Purchase__c
                WHERE Supplier__c IN :supplierIds
                GROUP BY Supplier__c
            ]) {
                Id sId = (Id) ar.get('Supplier__c');
                Decimal cost  = (Decimal) ar.get('totalCost');
                Decimal tax   = (Decimal) ar.get('totalTax');
                Decimal paid  = (Decimal) ar.get('totalPaid');
                cost  = cost  != null ? cost  : 0;
                tax   = tax   != null ? tax   : 0;
                paid  = paid  != null ? paid  : 0;
                Decimal out = Math.max(0, cost + tax - paid);
                supplierOutstanding.put(sId, out);
                supplierPurchaseCounts.put(
                    sId, Integer.valueOf(ar.get('purchaseCount'))
                );
            }
        }

        List<Map<String, Object>> supplierData =
            new List<Map<String, Object>>();
        for (Account s : suppliers) {
            Decimal out = supplierOutstanding.containsKey(s.Id)
                          ? supplierOutstanding.get(s.Id) : 0;
            Map<String, Object> row = new Map<String, Object>();
            row.put('id',        s.Id);
            row.put('name',      s.Name);
            row.put('phone',     s.Phone);
            row.put('outstanding', out);
            row.put('purchases', supplierPurchaseCounts.containsKey(s.Id)
                                 ? supplierPurchaseCounts.get(s.Id) : 0);
            supplierData.add(row);
        }

        return new Map<String, Object>{
            'clients'   => clientData,
            'suppliers' => supplierData
        };
    }

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