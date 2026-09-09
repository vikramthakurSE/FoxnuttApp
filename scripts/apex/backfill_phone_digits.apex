// One-time backfill: AccountTrigger (before update) recomputes Phone_Digits__c
List<Account> accs = [SELECT Id FROM Account WHERE Phone != null];
update accs;
System.debug('Backfilled ' + accs.size() + ' accounts');
