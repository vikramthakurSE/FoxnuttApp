trigger PurchaseLineItemTrigger on Purchase_Line_Item__c (
    after insert,
    after update,
    after delete,
    after undelete
) {
    if (Trigger.isAfter) {

        if (Trigger.isInsert || Trigger.isUndelete) {
            // New line items added — increase inventory
            PurchaseLineItemHelper.onInsert(Trigger.new);
        }
        else if (Trigger.isUpdate) {
            // Line item changed — adjust inventory by delta
            PurchaseLineItemHelper.onUpdate(Trigger.new, Trigger.oldMap);
        }
        else if (Trigger.isDelete) {
            // Line item deleted — decrease inventory
            PurchaseLineItemHelper.onDelete(Trigger.old);
        }
    }
}