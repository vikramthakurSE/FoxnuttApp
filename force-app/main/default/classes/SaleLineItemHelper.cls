public class SaleLineItemHelper {

    // ════════════════════════════════════════════════════════════════════════
    // BEFORE INSERT / BEFORE UPDATE
    // Validates stock + snapshots cost — does NOT touch inventory yet
    // ════════════════════════════════════════════════════════════════════════
    public static void validateAndSnapshotCost(
        List<Sale_Line_Item__c> newItems,
        Map<Id, Sale_Line_Item__c> oldMap
    ) {
        Set<String> keys = new Set<String>();
        for (Sale_Line_Item__c li : newItems) {
            if (li.Brand__c != null && li.Packet_Type__c != null)
                keys.add(li.Brand__c + '|' + li.Packet_Type__c);
        }

        Map<String, Inventory__c> invMap = queryInventory(keys);

        for (Sale_Line_Item__c li : newItems) {
            if (li.Brand__c == null || li.Packet_Type__c == null
                || li.Quantity__c == null) continue;

            String key = li.Brand__c + '|' + li.Packet_Type__c;
            Inventory__c inv = invMap.get(key);

            if (inv == null) {
                li.addError(
                    'No inventory found for ' + li.Brand__c +
                    ' (' + li.Packet_Type__c +
                    '). Purchase this brand first.'
                );
                continue;
            }

            // For stock validation: add back old qty on update
            Decimal available = inv.Remaining_Quantity__c != null
                                ? inv.Remaining_Quantity__c : 0;
            if (oldMap != null) {
                Sale_Line_Item__c oldLi = oldMap.get(li.Id);
                if (oldLi != null
                    && oldLi.Brand__c == li.Brand__c
                    && oldLi.Packet_Type__c == li.Packet_Type__c) {
                    available += (oldLi.Quantity__c != null
                                  ? oldLi.Quantity__c : 0);
                }
            }

            if (li.Quantity__c > available) {
                li.addError(
                    'Insufficient stock for ' + li.Brand__c +
                    ' (' + li.Packet_Type__c + '). ' +
                    'Available: ' + available.setScale(2) + ' KG. ' +
                    'Requested: ' + li.Quantity__c.setScale(2) + ' KG.'
                );
                continue;
            }

            // Snapshot cost only on insert or brand change
            Boolean isInsert = (oldMap == null);
            Boolean brandChanged = !isInsert && (
                oldMap.get(li.Id).Brand__c != li.Brand__c ||
                oldMap.get(li.Id).Packet_Type__c != li.Packet_Type__c
            );
            if (isInsert || brandChanged) {
                li.Cost_Per_Kg__c = inv.Avg_Cost_Per_Kg__c != null
                                    ? inv.Avg_Cost_Per_Kg__c : 0;
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // AFTER INSERT / AFTER UNDELETE
    // Only updates Account balance — inventory deducted on Delivered
    // ════════════════════════════════════════════════════════════════════════
    public static void onInsert(List<Sale_Line_Item__c> newItems) {
        // Check if parent sale is already Delivered (edge case)
        Set<Id> saleIds = new Set<Id>();
        for (Sale_Line_Item__c li : newItems) {
            if (li.Sale__c != null) saleIds.add(li.Sale__c);
        }

        Map<Id, Sale__c> saleMap = new Map<Id, Sale__c>([
            SELECT Id, Order_Status__c FROM Sale__c
            WHERE Id IN :saleIds
        ]);

        // Only deduct inventory if sale is already Delivered
        Map<String, Decimal> deductions = new Map<String, Decimal>();
        for (Sale_Line_Item__c li : newItems) {
            Sale__c s = saleMap.get(li.Sale__c);
            if (s != null && s.Order_Status__c == 'Delivered'
                && li.Brand__c != null && li.Quantity__c != null) {
                String key = li.Brand__c + '|' + li.Packet_Type__c;
                deductions.put(key,
                    (deductions.containsKey(key)
                     ? deductions.get(key) : 0) + li.Quantity__c);
            }
        }
        if (!deductions.isEmpty()) applyDeduction(deductions);

        // Always update account balances
        updateAccountBalancesAsync(saleIds);

        // Send new sale email
        EmailNotificationHelper.sendNewSaleAlert(newItems);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Called from SaleTrigger when Order_Status__c → Delivered
    // This is the main inventory deduction point
    // ════════════════════════════════════════════════════════════════════════
    public static void onStatusDelivered(Set<Id> saleIds) {
        List<Sale_Line_Item__c> lineItems = [
            SELECT Id, Sale__c, Brand__c, Packet_Type__c, Quantity__c
            FROM Sale_Line_Item__c
            WHERE Sale__c IN :saleIds
        ];
        if (lineItems.isEmpty()) return;

        Map<String, Decimal> deductions = new Map<String, Decimal>();
        for (Sale_Line_Item__c li : lineItems) {
            if (li.Brand__c == null || li.Quantity__c == null) continue;
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            deductions.put(key,
                (deductions.containsKey(key)
                 ? deductions.get(key) : 0) + li.Quantity__c);
        }
        if (!deductions.isEmpty()) applyDeduction(deductions);
    }

    // ════════════════════════════════════════════════════════════════════════
    // Called from SaleTrigger when Delivered → Cancelled/other
    // Returns stock back to inventory
    // ════════════════════════════════════════════════════════════════════════
    public static void onStatusUndelivered(Set<Id> saleIds) {
        List<Sale_Line_Item__c> lineItems = [
            SELECT Id, Sale__c, Brand__c, Packet_Type__c, Quantity__c
            FROM Sale_Line_Item__c
            WHERE Sale__c IN :saleIds
        ];
        if (lineItems.isEmpty()) return;

        Map<String, Decimal> returns = new Map<String, Decimal>();
        for (Sale_Line_Item__c li : lineItems) {
            if (li.Brand__c == null || li.Quantity__c == null) continue;
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            returns.put(key,
                (returns.containsKey(key)
                 ? returns.get(key) : 0) + li.Quantity__c);
        }
        if (!returns.isEmpty()) applyReturn(returns);
    }

    // ════════════════════════════════════════════════════════════════════════
    // AFTER UPDATE — only adjust inventory if sale is Delivered
    // ════════════════════════════════════════════════════════════════════════
    public static void onUpdate(
        List<Sale_Line_Item__c> newItems,
        Map<Id, Sale_Line_Item__c> oldMap
    ) {
        // Only touch inventory for Delivered sales
        Set<Id> saleIds = new Set<Id>();
        for (Sale_Line_Item__c li : newItems)
            if (li.Sale__c != null) saleIds.add(li.Sale__c);

        Map<Id, Sale__c> saleMap = new Map<Id, Sale__c>([
            SELECT Id, Order_Status__c FROM Sale__c
            WHERE Id IN :saleIds
        ]);

        Map<String, Decimal> deductions = new Map<String, Decimal>();
        Map<String, Decimal> returns    = new Map<String, Decimal>();

        for (Sale_Line_Item__c newLi : newItems) {
            Sale__c s = saleMap.get(newLi.Sale__c);
            if (s == null || s.Order_Status__c != 'Delivered') continue;

            Sale_Line_Item__c oldLi = oldMap.get(newLi.Id);
            String newKey = newLi.Brand__c + '|' + newLi.Packet_Type__c;
            String oldKey = oldLi.Brand__c + '|' + oldLi.Packet_Type__c;
            Decimal newQty = newLi.Quantity__c != null ? newLi.Quantity__c : 0;
            Decimal oldQty = oldLi.Quantity__c != null ? oldLi.Quantity__c : 0;

            if (newKey == oldKey) {
                Decimal delta = newQty - oldQty;
                if (delta > 0) {
                    deductions.put(newKey,
                        (deductions.containsKey(newKey)
                         ? deductions.get(newKey) : 0) + delta);
                } else if (delta < 0) {
                    returns.put(newKey,
                        (returns.containsKey(newKey)
                         ? returns.get(newKey) : 0) + Math.abs(delta));
                }
            } else {
                returns.put(oldKey,
                    (returns.containsKey(oldKey)
                     ? returns.get(oldKey) : 0) + oldQty);
                deductions.put(newKey,
                    (deductions.containsKey(newKey)
                     ? deductions.get(newKey) : 0) + newQty);
            }
        }

        if (!returns.isEmpty())    applyReturn(returns);
        if (!deductions.isEmpty()) applyDeduction(deductions);
        updateAccountBalancesAsync(saleIds);
    }

    // ════════════════════════════════════════════════════════════════════════
    // AFTER DELETE — only return stock if sale was Delivered
    // ════════════════════════════════════════════════════════════════════════
    public static void onDelete(List<Sale_Line_Item__c> oldItems) {
        Set<Id> saleIds = new Set<Id>();
        for (Sale_Line_Item__c li : oldItems)
            if (li.Sale__c != null) saleIds.add(li.Sale__c);

        Map<Id, Sale__c> saleMap = new Map<Id, Sale__c>([
            SELECT Id, Order_Status__c FROM Sale__c
            WHERE Id IN :saleIds
        ]);

        Map<String, Decimal> returns = new Map<String, Decimal>();
        for (Sale_Line_Item__c li : oldItems) {
            Sale__c s = saleMap.get(li.Sale__c);
            if (s == null || s.Order_Status__c != 'Delivered') continue;
            if (li.Brand__c == null || li.Quantity__c == null) continue;
            String key = li.Brand__c + '|' + li.Packet_Type__c;
            returns.put(key,
                (returns.containsKey(key)
                 ? returns.get(key) : 0) + li.Quantity__c);
        }
        if (!returns.isEmpty()) applyReturn(returns);
        updateAccountBalancesAsync(saleIds);
    }

    // ════════════════════════════════════════════════════════════════════════
    // PRIVATE HELPERS
    // ════════════════════════════════════════════════════════════════════════

    private static void applyDeduction(
        Map<String, Decimal> deductions
    ) {
        if (deductions.isEmpty()) return;
        Map<String, Inventory__c> invMap =
            queryInventory(deductions.keySet());
        List<Inventory__c> toUpdate = new List<Inventory__c>();

        for (String key : deductions.keySet()) {
            if (!invMap.containsKey(key)) continue;
            Inventory__c inv = invMap.get(key);
            Decimal qty = deductions.get(key);
            inv.Remaining_Quantity__c = Math.max(0,
                (inv.Remaining_Quantity__c != null
                 ? inv.Remaining_Quantity__c : 0) - qty);
            inv.Quantity_Sold__c =
                (inv.Quantity_Sold__c != null
                 ? inv.Quantity_Sold__c : 0) + qty;
            toUpdate.add(inv);
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    private static void applyReturn(Map<String, Decimal> returns) {
        if (returns.isEmpty()) return;
        Map<String, Inventory__c> invMap =
            queryInventory(returns.keySet());
        List<Inventory__c> toUpdate = new List<Inventory__c>();

        for (String key : returns.keySet()) {
            if (!invMap.containsKey(key)) continue;
            Inventory__c inv = invMap.get(key);
            Decimal qty = returns.get(key);
            inv.Remaining_Quantity__c =
                (inv.Remaining_Quantity__c != null
                 ? inv.Remaining_Quantity__c : 0) + qty;
            inv.Quantity_Sold__c = Math.max(0,
                (inv.Quantity_Sold__c != null
                 ? inv.Quantity_Sold__c : 0) - qty);
            toUpdate.add(inv);
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    @future
    public static void updateAccountBalancesAsync(Set<Id> saleIds) {
        Set<Id> accountIds = new Set<Id>();
        for (Sale__c s : [
            SELECT Client__c FROM Sale__c
            WHERE Id IN :saleIds AND Client__c != null
        ]) { accountIds.add(s.Client__c); }
        if (accountIds.isEmpty()) return;

        Map<Id, Decimal> totalBalance = new Map<Id, Decimal>();
        for (Id accId : accountIds) totalBalance.put(accId, 0);

        for (AggregateResult ar : [
            SELECT Client__c, SUM(Balance_Due__c) total
            FROM Sale__c
            WHERE Client__c IN :accountIds
            AND Balance_Due__c > 0
            AND Order_Status__c = 'Delivered'
            GROUP BY Client__c
        ]) {
            totalBalance.put(
                (Id) ar.get('Client__c'),
                (Decimal) ar.get('total')
            );
        }

        List<Account> toUpdate = new List<Account>();
        for (Id accId : accountIds) {
            toUpdate.add(new Account(
                Id = accId,
                Account_Balance__c = totalBalance.get(accId)
            ));
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

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
                   Remaining_Quantity__c, Quantity_Sold__c,
                   Avg_Cost_Per_Kg__c
            FROM Inventory__c
            WHERE Brand__c IN :brands
            AND   Packet_Type__c IN :types
        ]) {
            invMap.put(inv.Brand__c + '|' + inv.Packet_Type__c, inv);
        }
        return invMap;
    }
}