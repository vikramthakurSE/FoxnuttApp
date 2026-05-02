public class PurchaseLineItemHelper {

    // ── Called on AFTER INSERT ─────────────────────────────
    public static void onInsert(
        List<Purchase_Line_Item__c> newItems
    ) {
        // Collect parent Purchase IDs to get Order_Date__c
        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }

        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Order_Date__c
            FROM Purchase__c
            WHERE Id IN :purchaseIds
        ]);

        // Collect Brand|PacketType keys
        Set<String> keys = new Set<String>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Brand__c != null && li.Packet_Type__c != null) {
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
            }
        }

        Map<String, Inventory__c> invMap = queryInventory(keys);

        // Group line items by composite key
        Map<String, List<Purchase_Line_Item__c>> grouped =
            new Map<String, List<Purchase_Line_Item__c>>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Brand__c == null || li.Packet_Type__c == null)
                continue;
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            if (!grouped.containsKey(key)) {
                grouped.put(key, new List<Purchase_Line_Item__c>());
            }
            grouped.get(key).add(li);
        }

        List<Inventory__c> toUpsert = new List<Inventory__c>();

        for (String key : grouped.keySet()) {
            List<Purchase_Line_Item__c> items = grouped.get(key);
            List<String> parts = key.split('\\|');
            String brand      = parts[0];
            String packetType = parts[1];

            // Sum qty and compute weighted avg cost across all items
            Decimal totalQty  = 0;
            Decimal totalCost = 0;
            Date    orderDate = null;

            for (Purchase_Line_Item__c li : items) {
                Decimal qty  = li.Quantity__c != null
                               ? li.Quantity__c : 0;
                Decimal cost = li.Landing_Cost_Per_Kg__c != null
                               ? li.Landing_Cost_Per_Kg__c : 0;
                totalQty  += qty;
                totalCost += qty * cost;

                // Use the purchase's Order_Date__c — not today
                if (li.Purchase__c != null &&
                    purchaseMap.containsKey(li.Purchase__c)) {
                    Date purDate =
                        purchaseMap.get(li.Purchase__c).Order_Date__c;
                    if (purDate != null &&
                        (orderDate == null || purDate > orderDate)) {
                        orderDate = purDate;
                    }
                }
            }

            Inventory__c inv = invMap.containsKey(key)
                               ? invMap.get(key) : new Inventory__c();

            if (inv.Id == null) {
                // Create new inventory record
                inv.Brand__c        = brand;
                inv.Packet_Type__c  = packetType;
                inv.Total_Quantity__c     = totalQty;
                inv.Remaining_Quantity__c = totalQty;
                inv.Quantity_Sold__c      = 0;
                inv.Avg_Cost_Per_Kg__c    = totalQty > 0
                    ? totalCost / totalQty : 0;
            } else {
                // Update existing — weighted average cost
                Decimal existingQty  = inv.Total_Quantity__c != null
                                       ? inv.Total_Quantity__c : 0;
                Decimal existingCost = inv.Avg_Cost_Per_Kg__c != null
                                       ? inv.Avg_Cost_Per_Kg__c : 0;
                Decimal combinedQty  = existingQty + totalQty;
                Decimal combinedCost = (existingQty * existingCost)
                                       + totalCost;

                inv.Total_Quantity__c     += totalQty;
                inv.Remaining_Quantity__c =
                    (inv.Remaining_Quantity__c != null
                     ? inv.Remaining_Quantity__c : 0) + totalQty;
                inv.Avg_Cost_Per_Kg__c    = combinedQty > 0
                    ? combinedCost / combinedQty : 0;
            }

            // Set Last_Purchase_Date__c from Order_Date__c
            // NOT from Date.today()
            if (orderDate != null) {
                inv.Last_Purchase_Date__c = orderDate;
            }

            toUpsert.add(inv);
        }

        if (!toUpsert.isEmpty()) upsert toUpsert;

        // Send email notification
        EmailNotificationHelper.sendNewPurchaseAlert(newItems);
    }

    // ── Called on AFTER UPDATE ─────────────────────────────
    public static void onUpdate(
        List<Purchase_Line_Item__c> newItems,
        Map<Id, Purchase_Line_Item__c> oldMap
    ) {
        // Collect Purchase IDs
        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }
        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Order_Date__c
            FROM Purchase__c WHERE Id IN :purchaseIds
        ]);

        Set<String> keys = new Set<String>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Brand__c != null && li.Packet_Type__c != null)
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
        }
        for (Purchase_Line_Item__c li : oldMap.values()) {
            if (li.Brand__c != null && li.Packet_Type__c != null)
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
        }

        Map<String, Inventory__c> invMap = queryInventory(keys);
        List<Inventory__c> toUpdate = new List<Inventory__c>();

        for (Purchase_Line_Item__c newLi : newItems) {
            Purchase_Line_Item__c oldLi = oldMap.get(newLi.Id);
            String newKey = newLi.Brand__c + '|' + newLi.Packet_Type__c;
            String oldKey = oldLi.Brand__c + '|' + oldLi.Packet_Type__c;

            Decimal newQty  = newLi.Quantity__c != null
                              ? newLi.Quantity__c : 0;
            Decimal oldQty  = oldLi.Quantity__c != null
                              ? oldLi.Quantity__c : 0;
            Decimal delta   = newQty - oldQty;

            if (newKey == oldKey && delta != 0
                && invMap.containsKey(newKey)) {
                Inventory__c inv = invMap.get(newKey);
                inv.Total_Quantity__c =
                    (inv.Total_Quantity__c != null
                     ? inv.Total_Quantity__c : 0) + delta;
                inv.Remaining_Quantity__c = Math.max(0,
                    (inv.Remaining_Quantity__c != null
                     ? inv.Remaining_Quantity__c : 0) + delta);

                // Update Last_Purchase_Date__c using Order_Date__c
                if (newLi.Purchase__c != null &&
                    purchaseMap.containsKey(newLi.Purchase__c)) {
                    Date purDate =
                        purchaseMap.get(newLi.Purchase__c).Order_Date__c;
                    if (purDate != null &&
                        (inv.Last_Purchase_Date__c == null ||
                         purDate > inv.Last_Purchase_Date__c)) {
                        inv.Last_Purchase_Date__c = purDate;
                    }
                }
                toUpdate.add(inv);
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // ── Called on AFTER DELETE ─────────────────────────────
    public static void onDelete(
        List<Purchase_Line_Item__c> oldItems
    ) {
        Set<String> keys = new Set<String>();
        for (Purchase_Line_Item__c li : oldItems) {
            if (li.Brand__c != null && li.Packet_Type__c != null)
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
        }

        Map<String, Inventory__c> invMap = queryInventory(keys);
        List<Inventory__c> toUpdate = new List<Inventory__c>();

        // Group deletions by key
        Map<String, Decimal> qtyToReturn = new Map<String, Decimal>();
        for (Purchase_Line_Item__c li : oldItems) {
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            Decimal qty = li.Quantity__c != null ? li.Quantity__c : 0;
            qtyToReturn.put(key,
                (qtyToReturn.containsKey(key)
                 ? qtyToReturn.get(key) : 0) + qty);
        }

        for (String key : qtyToReturn.keySet()) {
            if (!invMap.containsKey(key)) continue;
            Inventory__c inv = invMap.get(key);
            Decimal qty = qtyToReturn.get(key);
            inv.Total_Quantity__c = Math.max(0,
                (inv.Total_Quantity__c != null
                 ? inv.Total_Quantity__c : 0) - qty);
            inv.Remaining_Quantity__c = Math.max(0,
                (inv.Remaining_Quantity__c != null
                 ? inv.Remaining_Quantity__c : 0) - qty);
            toUpdate.add(inv);
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // ── Private helper ─────────────────────────────────────
    private static Map<String, Inventory__c> queryInventory(
        Set<String> keys
    ) {
        Set<String> brands = new Set<String>();
        Set<String> types  = new Set<String>();
        for (String key : keys) {
            List<String> parts = key.split('\\|');
            brands.add(parts[0]);
            types.add(parts[1]);
        }
        Map<String, Inventory__c> invMap =
            new Map<String, Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Brand__c, Packet_Type__c,
                   Total_Quantity__c, Remaining_Quantity__c,
                   Quantity_Sold__c, Avg_Cost_Per_Kg__c,
                   Last_Purchase_Date__c
            FROM Inventory__c
            WHERE Brand__c IN :brands
            AND   Packet_Type__c IN :types
        ]) {
            invMap.put(
                inv.Brand__c + '|' + inv.Packet_Type__c, inv
            );
        }
        return invMap;
    }
}