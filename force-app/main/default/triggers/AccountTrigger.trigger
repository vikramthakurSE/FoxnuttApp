trigger AccountTrigger on Account (before insert, before update, after insert) {

    // Keep Phone_Digits__c (last 10 digits) in sync for website phone matching
    if (Trigger.isBefore) {
        for (Account a : Trigger.new) {
            a.Phone_Digits__c = WebStoreService.normalizePhone(a.Phone);
        }
    }

    // Stamp the website login code on new accounts. Only on insert: the code
    // goes out in the welcome message, so recalculating it after a rename
    // would silently lock the client out of the store.
    if (Trigger.isBefore && Trigger.isInsert) {
        WebStoreService.assignBusinessCodes(Trigger.new);
    }

    if (Trigger.isAfter && Trigger.isInsert) {

        // Get Client RecordType ID once
        Id clientRTId;
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account'
            AND Name = 'Client'
            LIMIT 1
        ];
        if (!rts.isEmpty()) clientRTId = rts[0].Id;

        // Re-query for the generated code — Trigger.new holds the values set
        // before insert, but reading them back keeps this honest if another
        // before-trigger or a flow overwrote them.
        Map<Id, Account> withCodes = new Map<Id, Account>([
            SELECT Id, Name, Phone, Unique_Business_Code__c
            FROM Account WHERE Id IN :Trigger.newMap.keySet()
        ]);

        List<Account> toWelcome = new List<Account>();
        for (Account a : Trigger.new) {
            if (String.isNotBlank(a.Phone) &&
                clientRTId != null &&
                a.RecordTypeId == clientRTId) {
                toWelcome.add(withCodes.get(a.Id));
            }
        }

        if (!toWelcome.isEmpty()) {
            WhatsAppHelper.dispatchWelcome(toWelcome);
        }
    }
}
