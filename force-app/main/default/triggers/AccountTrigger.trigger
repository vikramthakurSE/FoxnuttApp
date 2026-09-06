trigger AccountTrigger on Account (before insert, before update, after insert) {

    // Keep Phone_Digits__c (last 10 digits) in sync for website phone matching
    if (Trigger.isBefore) {
        for (Account a : Trigger.new) {
            a.Phone_Digits__c = WebStoreService.normalizePhone(a.Phone);
        }
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

        List<Account> toWelcome = new List<Account>();
        for (Account a : Trigger.new) {
            if (String.isNotBlank(a.Phone) &&
                clientRTId != null &&
                a.RecordTypeId == clientRTId) {
                toWelcome.add(a);
            }
        }

        if (!toWelcome.isEmpty()) {
            WhatsAppHelper.dispatchWelcome(toWelcome);
        }
    }
}
