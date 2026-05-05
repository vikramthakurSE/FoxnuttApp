public class PurchaseLineItemHelper {

    // ── AFTER INSERT ───────────────────────────────────────────────────────
    // Only update inventory if the parent purchase is already 'Received'
    // (handles edge case of line items added directly on a received order)
    public static void onInsert(List<Purchase_Line_Item__c> newItems) {
        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }

        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Order_Date__c, Delivery_Status__c
            FROM Purchase__c WHERE Id IN :purchaseIds
        ]);

        // Only add to inventory for already-received purchases
        List<Purchase_Line_Item__c> receivedItems =
            new List<Purchase_Line_Item__c>();
        for (Purchase_Line_Item__c li : newItems) {
            Purchase__c p = purchaseMap.get(li.Purchase__c);
            if (p != null && p.Delivery_Status__c == 'Received') {
                receivedItems.add(li);
            }
        }

        if (!receivedItems.isEmpty()) {
            applyInventoryAddition(receivedItems, purchaseMap);
        }
        // NOTE: email is now sent from QuickPurchaseController.updateTax
        // so it includes tax info
    }

    // ── Called from PurchaseTrigger when status → Received ────────────────
    // This is the main inventory creation point
    public static void onStatusReceived(Set<Id> purchaseIds) {
        List<Purchase_Line_Item__c> lineItems = [
            SELECT Id, Purchase__c, Brand__c, Packet_Type__c,
                   Quantity__c, Landing_Cost_Per_Kg__c, Shrinkage__c
            FROM Purchase_Line_Item__c
            WHERE Purchase__c IN :purchaseIds
        ];
        if (lineItems.isEmpty()) return;

        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Order_Date__c, Delivery_Status__c
            FROM Purchase__c WHERE Id IN :purchaseIds
        ]);

        applyInventoryAddition(lineItems, purchaseMap);
    }

    // ── AFTER UPDATE ───────────────────────────────────────────────────────
    public static void onUpdate(
        List<Purchase_Line_Item__c> newItems,
        Map<Id, Purchase_Line_Item__c> oldMap
    ) {
        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : newItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }

        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Order_Date__c, Delivery_Status__c
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
            Purchase__c p = purchaseMap.get(newLi.Purchase__c);

            // Only touch inventory if purchase is Received
            if (p == null || p.Delivery_Status__c != 'Received') continue;

            String newKey = newLi.Brand__c + '|' + newLi.Packet_Type__c;

            // Handle quantity changes
            Decimal newQty = newLi.Quantity__c != null ? newLi.Quantity__c : 0;
            Decimal oldQty = oldLi.Quantity__c != null ? oldLi.Quantity__c : 0;
            Decimal qtyDelta = newQty - oldQty;

            // Handle shrinkage changes — Issue 4 fix
            Decimal newShrink = newLi.Shrinkage__c != null ? newLi.Shrinkage__c : 0;
            Decimal oldShrink = oldLi.Shrinkage__c != null ? oldLi.Shrinkage__c : 0;
            Decimal shrinkDelta = newShrink - oldShrink;

            if ((qtyDelta != 0 || shrinkDelta != 0) &&
                invMap.containsKey(newKey)) {
                Inventory__c inv = invMap.get(newKey);

                if (qtyDelta != 0) {
                    inv.Total_Quantity__c = (inv.Total_Quantity__c != null
                        ? inv.Total_Quantity__c : 0) + qtyDelta;
                }

                // Remaining = Total - Sold - Shrinkage
                // When shrinkage increases, remaining decreases
                Decimal total = inv.Total_Quantity__c != null
                    ? inv.Total_Quantity__c : 0;
                Decimal sold = inv.Quantity_Sold__c != null
                    ? inv.Quantity_Sold__c : 0;
                Decimal totalShrink = (inv.Shrinkage__c != null
                    ? inv.Shrinkage__c : 0) + shrinkDelta;

                inv.Shrinkage__c = Math.max(0, totalShrink);
                inv.Remaining_Quantity__c = Math.max(0,
                    total - sold - inv.Shrinkage__c);

                toUpdate.add(inv);
            }
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // ── AFTER DELETE ───────────────────────────────────────────────────────
    public static void onDelete(List<Purchase_Line_Item__c> oldItems) {
        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : oldItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }

        Map<Id, Purchase__c> purchaseMap = new Map<Id, Purchase__c>([
            SELECT Id, Delivery_Status__c
            FROM Purchase__c WHERE Id IN :purchaseIds
        ]);

        // Only reverse inventory if purchase was Received
        List<Purchase_Line_Item__c> receivedItems =
            new List<Purchase_Line_Item__c>();
        for (Purchase_Line_Item__c li : oldItems) {
            Purchase__c p = purchaseMap.get(li.Purchase__c);
            if (p != null && p.Delivery_Status__c == 'Received') {
                receivedItems.add(li);
            }
        }
        if (receivedItems.isEmpty()) return;

        Set<String> keys = new Set<String>();
        for (Purchase_Line_Item__c li : receivedItems) {
            if (li.Brand__c != null && li.Packet_Type__c != null)
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
        }

        Map<String, Inventory__c> invMap = queryInventory(keys);
        Map<String, Decimal> qtyToReturn = new Map<String, Decimal>();

        for (Purchase_Line_Item__c li : receivedItems) {
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            Decimal qty = li.Quantity__c != null ? li.Quantity__c : 0;
            qtyToReturn.put(key,
                (qtyToReturn.containsKey(key)
                 ? qtyToReturn.get(key) : 0) + qty);
        }

        List<Inventory__c> toUpdate = new List<Inventory__c>();
        for (String key : qtyToReturn.keySet()) {
            if (!invMap.containsKey(key)) continue;
            Inventory__c inv = invMap.get(key);
            Decimal qty = qtyToReturn.get(key);
            inv.Total_Quantity__c = Math.max(0,
                (inv.Total_Quantity__c != null ? inv.Total_Quantity__c : 0)
                - qty);
            inv.Remaining_Quantity__c = Math.max(0,
                (inv.Remaining_Quantity__c != null
                 ? inv.Remaining_Quantity__c : 0) - qty);
            toUpdate.add(inv);
        }

        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // ── Shared: add line items to inventory ────────────────────────────────
    private static void applyInventoryAddition(
        List<Purchase_Line_Item__c> items,
        Map<Id, Purchase__c> purchaseMap
    ) {
        Set<String> keys = new Set<String>();
        for (Purchase_Line_Item__c li : items) {
            if (li.Brand__c != null && li.Packet_Type__c != null)
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
        }

        Map<String, Inventory__c> invMap = queryInventory(keys);

        // Group by composite key
        Map<String, List<Purchase_Line_Item__c>> grouped =
            new Map<String, List<Purchase_Line_Item__c>>();
        for (Purchase_Line_Item__c li : items) {
            if (li.Brand__c == null || li.Packet_Type__c == null) continue;
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            if (!grouped.containsKey(key))
                grouped.put(key, new List<Purchase_Line_Item__c>());
            grouped.get(key).add(li);
        }

        List<Inventory__c> toUpsert = new List<Inventory__c>();

        for (String key : grouped.keySet()) {
            List<Purchase_Line_Item__c> groups = grouped.get(key);
            List<String> parts = key.split('\\|');
            String brand      = parts[0];
            String packetType = parts[1];

            Decimal totalQty   = 0;
            Decimal totalCost  = 0;
            Decimal totalShrink = 0;
            Date    orderDate  = null;

            for (Purchase_Line_Item__c li : groups) {
                Decimal qty  = li.Quantity__c != null ? li.Quantity__c : 0;
                Decimal cost = li.Landing_Cost_Per_Kg__c != null
                               ? li.Landing_Cost_Per_Kg__c : 0;
                totalQty   += qty;
                totalCost  += qty * cost;
                totalShrink += li.Shrinkage__c != null ? li.Shrinkage__c : 0;

                if (li.Purchase__c != null &&
                    purchaseMap.containsKey(li.Purchase__c)) {
                    Date purDate =
                        purchaseMap.get(li.Purchase__c).Order_Date__c;
                    if (purDate != null &&
                        (orderDate == null || purDate > orderDate))
                        orderDate = purDate;
                }
            }

            Inventory__c inv = invMap.containsKey(key)
                               ? invMap.get(key) : new Inventory__c();

            if (inv.Id == null) {
                // New inventory record
                inv.Brand__c              = brand;
                inv.Packet_Type__c        = packetType;
                inv.Total_Quantity__c     = totalQty;
                inv.Shrinkage__c          = totalShrink;
                inv.Remaining_Quantity__c = Math.max(0,
                    totalQty - totalShrink);
                inv.Quantity_Sold__c      = 0;
                inv.Avg_Cost_Per_Kg__c    = totalQty > 0
                    ? totalCost / totalQty : 0;
            } else {
                // Update — weighted average cost
                Decimal existingQty  = inv.Total_Quantity__c != null
                                       ? inv.Total_Quantity__c : 0;
                Decimal existingCost = inv.Avg_Cost_Per_Kg__c != null
                                       ? inv.Avg_Cost_Per_Kg__c : 0;
                Decimal combinedQty  = existingQty + totalQty;
                Decimal combinedCost = (existingQty * existingCost) + totalCost;

                inv.Total_Quantity__c    = combinedQty;
                inv.Avg_Cost_Per_Kg__c   = combinedQty > 0
                    ? combinedCost / combinedQty : 0;
                inv.Shrinkage__c = (inv.Shrinkage__c != null
                    ? inv.Shrinkage__c : 0) + totalShrink;
                inv.Remaining_Quantity__c = Math.max(0,
                    inv.Total_Quantity__c
                    - (inv.Quantity_Sold__c != null ? inv.Quantity_Sold__c : 0)
                    - inv.Shrinkage__c);
            }

            if (orderDate != null)
                inv.Last_Purchase_Date__c = orderDate;

            toUpsert.add(inv);
        }

        if (!toUpsert.isEmpty()) upsert toUpsert;
    }

    // ── Query helper ───────────────────────────────────────────────────────
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
        Map<String, Inventory__c> invMap = new Map<String, Inventory__c>();
        for (Inventory__c inv : [
            SELECT Id, Brand__c, Packet_Type__c,
                   Total_Quantity__c, Remaining_Quantity__c,
                   Quantity_Sold__c, Avg_Cost_Per_Kg__c,
                   Shrinkage__c, Last_Purchase_Date__c
            FROM Inventory__c
            WHERE Brand__c IN :brands
            AND   Packet_Type__c IN :types
        ]) {
            invMap.put(inv.Brand__c + '|' + inv.Packet_Type__c, inv);
        }
        return invMap;
    }
}