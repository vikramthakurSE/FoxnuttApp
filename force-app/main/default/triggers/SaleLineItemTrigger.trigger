trigger SaleLineItemTrigger on Sale_Line_Item__c (
    before insert,
    after  insert,
    before update,
    after  update,
    after  delete,
    after  undelete
) {
    // BEFORE INSERT — validate stock + snapshot cost
    if (Trigger.isBefore && Trigger.isInsert) {
        SaleLineItemHelper.validateAndSnapshotCost(Trigger.new, null);
    }

    // BEFORE UPDATE — re-snapshot cost if brand/type changed
    if (Trigger.isBefore && Trigger.isUpdate) {
        SaleLineItemHelper.validateAndSnapshotCost(
            Trigger.new, Trigger.oldMap
        );
    }

    // AFTER INSERT — only update account balance
    // Inventory NOT deducted here — deducted on Delivered status
    if (Trigger.isAfter && Trigger.isInsert) {
        SaleLineItemHelper.onInsert(Trigger.new);
    }

    // AFTER UPDATE — adjust inventory only if sale is Delivered
    if (Trigger.isAfter && Trigger.isUpdate) {
        SaleLineItemHelper.onUpdate(Trigger.new, Trigger.oldMap);
    }

    // AFTER DELETE — return stock only if sale was Delivered
    if (Trigger.isAfter && Trigger.isDelete) {
        SaleLineItemHelper.onDelete(Trigger.old);
    }

    // AFTER UNDELETE — same as insert
    if (Trigger.isAfter && Trigger.isUndelete) {
        SaleLineItemHelper.onInsert(Trigger.new);
    }
}
