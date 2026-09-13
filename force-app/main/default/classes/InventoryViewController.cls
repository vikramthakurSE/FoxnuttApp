public with sharing class InventoryViewController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getInventory() {
        // Inventory records
        List<Inventory__c> items = [
            SELECT Id, Name, Brand__c, Packet_Type__c,
                   Total_Quantity__c, Remaining_Quantity__c,
                   Quantity_Sold__c, Avg_Cost_Per_Kg__c,
                   Packet_Count__c, Shrinkage__c, Shrinkage_Notes__c,
                   Shrinkage_History__c, Last_Purchase_Date__c
            FROM Inventory__c
            ORDER BY Remaining_Quantity__c DESC NULLS LAST,
                     Brand__c ASC
        ];

        // Blocked qty = active sales (Confirmed / Out for Delivery)
        // not yet delivered — salesman should see this as reserved
        Map<String, Decimal> blockedMap = new Map<String, Decimal>();
        for (AggregateResult ar : [
            SELECT Brand__c brand, Packet_Type__c packetType,
                   SUM(Quantity__c) qty
            FROM Sale_Line_Item__c
            WHERE Sale__r.Order_Status__c IN ('Confirmed', 'Out for Delivery')
            AND Quantity__c != null
            GROUP BY Brand__c, Packet_Type__c
        ]) {
            String key = (String) ar.get('brand') + '|' +
                         (String) ar.get('packetType');
            Decimal qty = (Decimal) ar.get('qty');
            blockedMap.put(key, qty != null ? qty : 0);
        }

        // Build blocked list for JS consumption
        List<Map<String, Object>> blockedList =
            new List<Map<String, Object>>();
        for (String key : blockedMap.keySet()) {
            List<String> parts = key.split('\\|');
            blockedList.add(new Map<String, Object>{
                'key'        => key,
                'brand'      => parts[0],
                'packetType' => parts.size() > 1 ? parts[1] : '',
                'blocked'    => blockedMap.get(key)
            });
        }

        return new Map<String, Object>{
            'inventory' => items,
            'blocked'   => blockedList
        };
    }

    // ── Quarterly sales performance ───────────────────────────────────────
    // Rolls up Sale Line Items into calendar quarters (matching the
    // Qtr{n}_{year} convention used by Sale__c.Quarter__c) so the inventory
    // screen can be viewed one quarter at a time. Every quarter in the
    // window is returned — even ones with no sales — so the selector always
    // offers the same set of periods.
    private static final Integer QUARTERS_IN_WINDOW = 8;   // ~2 years

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getQuarterlySales() {
        Date today       = Date.today();
        Integer curQtr   = (today.month() + 2) / 3;
        Date   curStart  = Date.newInstance(today.year(), (curQtr - 1) * 3 + 1, 1);
        Date   windowStart = curStart.addMonths(-3 * (QUARTERS_IN_WINDOW - 1));

        // Seed every quarter in the window, newest first
        List<Map<String, Object>> quarters = new List<Map<String, Object>>();
        Map<String, Map<String, Object>> byKey =
            new Map<String, Map<String, Object>>();
        Map<String, Map<String, Map<String, Object>>> brandsByKey =
            new Map<String, Map<String, Map<String, Object>>>();
        Map<String, Set<Id>> saleIdsByKey = new Map<String, Set<Id>>();

        for (Integer i = 0; i < QUARTERS_IN_WINDOW; i++) {
            Date qStart  = curStart.addMonths(-3 * i);
            Integer qNum = (qStart.month() + 2) / 3;
            String key   = 'Qtr' + qNum + '_' + qStart.year();

            Map<String, Object> q = new Map<String, Object>{
                'key'        => key,
                'label'      => 'Q' + qNum + ' ' + qStart.year(),
                'shortLabel' => 'Q' + qNum + ' \''  +
                                String.valueOf(qStart.year()).right(2),
                'rangeLabel' => monthName(qStart.month()) + ' – ' +
                                monthName(qStart.addMonths(2).month()) + ' ' +
                                qStart.year(),
                'startDate'  => String.valueOf(qStart),
                'endDate'    => String.valueOf(qStart.addMonths(3).addDays(-1)),
                'isCurrent'  => (i == 0),
                'orders'     => 0,
                'kgSold'     => 0.0,
                'revenue'    => 0.0,
                'profit'     => 0.0
            };
            quarters.add(q);
            byKey.put(key, q);
            brandsByKey.put(key, new Map<String, Map<String, Object>>());
            saleIdsByKey.put(key, new Set<Id>());
        }

        for (Sale_Line_Item__c li : [
            SELECT Id, Sale__c, Brand__c, Packet_Type__c,
                   Quantity__c, Line_Amount__c, Line_Profit__c,
                   Sale__r.Sale_Date__c,
                   Sale__r.Total_CD_Amount__c,
                   Sale__r.Total_Revenue__c
            FROM Sale_Line_Item__c
            WHERE Sale__r.Sale_Date__c >= :windowStart
            AND   Sale__r.Order_Status__c = 'Delivered'
        ]) {
            Date sd = li.Sale__r.Sale_Date__c;
            if (sd == null) continue;
            String key = 'Qtr' + ((sd.month() + 2) / 3) + '_' + sd.year();
            Map<String, Object> q = byKey.get(key);
            if (q == null) continue;   // outside the window

            Decimal qty      = li.Quantity__c    != null ? li.Quantity__c    : 0;
            Decimal lineAmt  = li.Line_Amount__c != null ? li.Line_Amount__c : 0;
            Decimal lineProf = li.Line_Profit__c != null ? li.Line_Profit__c : 0;
            Decimal saleCd   = li.Sale__r.Total_CD_Amount__c != null
                               ? li.Sale__r.Total_CD_Amount__c : 0;
            Decimal saleRev  = li.Sale__r.Total_Revenue__c != null
                               ? li.Sale__r.Total_Revenue__c : 0;

            // Apportion the sale's cash discount to this line by its share of
            // the sale's revenue — same basis as the brand detail modal.
            Decimal cdShare = saleRev > 0 ? (lineAmt / saleRev) * saleCd : 0;
            Decimal effRev  = Math.max(0, lineAmt - cdShare);
            Decimal effProf = lineProf - cdShare;   // a loss stays a loss

            saleIdsByKey.get(key).add(li.Sale__c);
            q.put('kgSold',  (Decimal) q.get('kgSold')  + qty);
            q.put('revenue', (Decimal) q.get('revenue') + effRev);
            q.put('profit',  (Decimal) q.get('profit')  + effProf);

            String bKey = (li.Brand__c == null ? '' : li.Brand__c) + '|' +
                          (li.Packet_Type__c == null ? '' : li.Packet_Type__c);
            Map<String, Map<String, Object>> brands = brandsByKey.get(key);
            Map<String, Object> b = brands.get(bKey);
            if (b == null) {
                b = new Map<String, Object>{
                    'key'        => bKey,
                    'brand'      => li.Brand__c,
                    'packetType' => li.Packet_Type__c,
                    'kgSold'     => 0.0,
                    'revenue'    => 0.0,
                    'profit'     => 0.0
                };
                brands.put(bKey, b);
            }
            b.put('kgSold',  (Decimal) b.get('kgSold')  + qty);
            b.put('revenue', (Decimal) b.get('revenue') + effRev);
            b.put('profit',  (Decimal) b.get('profit')  + effProf);
        }

        for (Map<String, Object> q : quarters) {
            String key = (String) q.get('key');
            q.put('orders', saleIdsByKey.get(key).size());
            q.put('brands', brandsByKey.get(key).values());
        }
        return quarters;
    }

    private static String monthName(Integer m) {
        List<String> names = new List<String>{
            'Jan','Feb','Mar','Apr','May','Jun',
            'Jul','Aug','Sep','Oct','Nov','Dec'
        };
        return names[m - 1];
    }

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getBrandDetail(
        String brand, String packetType
    ) {
        // Recent purchases for this brand
        List<Purchase_Line_Item__c> purchases = [
            SELECT Id, Purchase__r.Name,
                   Purchase__r.Order_Date__c,
                   Purchase__r.Supplier__r.Name,
                   Purchase__r.Delivery_Status__c,
                   Quantity__c, Landing_Cost_Per_Kg__c,
                   Line_Total__c, Shrinkage__c
            FROM Purchase_Line_Item__c
            WHERE Brand__c = :brand
            AND Packet_Type__c = :packetType
            ORDER BY Purchase__r.Order_Date__c DESC
            LIMIT 10
        ];

        // Recent sales for this brand. Delivered only — a cancelled or
        // still-in-flight order has not earned any revenue yet, and
        // Delivered is where SaleLineItemHelper deducts the stock, so
        // counting anything else here overstated revenue and profit.
        List<Sale_Line_Item__c> sales = [
            SELECT Id, Sale__r.Name,
                   Sale__r.Sale_Date__c,
                   Sale__r.Client__r.Name,
                   Sale__r.Total_CD_Amount__c,
                   Sale__r.Effective_Revenue__c,
                   Sale__r.Total_Revenue__c,
                   Quantity__c, Rate_Per_Kg__c,
                   Line_Amount__c, Line_Profit__c
            FROM Sale_Line_Item__c
            WHERE Brand__c = :brand
            AND Packet_Type__c = :packetType
            AND Sale__r.Order_Status__c = 'Delivered'
            ORDER BY Sale__r.Sale_Date__c DESC
            LIMIT 10
        ];

        return new Map<String, Object>{
            'purchases' => purchases,
            'sales'     => sales
        };
    }

    // Adds `addAmount` KG of shrinkage ON TOP of the running total (use a
    // negative amount to correct an over-entry), logs a dated history entry
    // with the reason, and recomputes Remaining = Total − Sold − Shrinkage.
    @AuraEnabled
    public static void updateShrinkage(
        Id inventoryId, Decimal addAmount, String notes
    ) {
        Inventory__c current = [
            SELECT Id, Total_Quantity__c, Quantity_Sold__c,
                   Shrinkage__c, Shrinkage_History__c
            FROM Inventory__c
            WHERE Id = :inventoryId
            LIMIT 1
        ];

        Decimal total   = current.Total_Quantity__c != null
                          ? current.Total_Quantity__c : 0;
        Decimal sold    = current.Quantity_Sold__c  != null
                          ? current.Quantity_Sold__c  : 0;
        Decimal curShrink = current.Shrinkage__c != null
                            ? current.Shrinkage__c : 0;
        Decimal add     = addAmount != null ? addAmount : 0;

        // Running total never goes below zero; log the amount that actually
        // applied so history stays consistent with the total.
        Decimal newShrink = curShrink + add;
        if (newShrink < 0) newShrink = 0;
        Decimal applied = newShrink - curShrink;

        Decimal remaining = Math.max(0, total - sold - newShrink);

        // Append a JSON history entry: {date, amount, notes}
        String entry = JSON.serialize(new Map<String, Object>{
            'date'   => String.valueOf(Date.today()),
            'amount' => applied,
            'notes'  => String.isBlank(notes) ? '' : notes.trim()
        });
        String hist = current.Shrinkage_History__c;
        String newHist = String.isBlank(hist)
            ? '[' + entry + ']'
            : hist.removeEnd(']') + ',' + entry + ']';

        // Packet_Count__c is a formula field — recomputed automatically
        update new Inventory__c(
            Id                    = inventoryId,
            Shrinkage__c          = newShrink,
            Shrinkage_Notes__c    = String.isBlank(notes) ? null : notes.trim(),
            Shrinkage_History__c  = newHist,
            Remaining_Quantity__c = remaining
        );
    }
}