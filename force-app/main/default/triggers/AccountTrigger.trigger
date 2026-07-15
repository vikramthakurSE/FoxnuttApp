trigger AccountTrigger on Account (after insert) {

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
