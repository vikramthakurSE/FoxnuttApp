// Stamp Unique_Business_Code__c onto every existing client account.
// Safe to re-run: accounts that already have a code are skipped.
// Run with: sf apex run -o Foxnutt -f scripts/apex/backfill_business_codes.apex

List<Account> toFix = [
    SELECT Id, Name, Phone, Unique_Business_Code__c
    FROM Account
    WHERE Unique_Business_Code__c = null AND Phone != null
    LIMIT 10000
];

WebStoreService.assignBusinessCodes(toFix);

List<Account> withCode = new List<Account>();
for (Account a : toFix) {
    if (String.isNotBlank(a.Unique_Business_Code__c)) withCode.add(a);
}
update withCode;

System.debug('Accounts scanned: ' + toFix.size());
System.debug('Codes assigned  : ' + withCode.size());
for (Account a : withCode) {
    System.debug(a.Name + '  ->  ' + a.Unique_Business_Code__c);
}
