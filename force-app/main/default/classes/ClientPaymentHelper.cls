public class ClientPaymentHelper {

    public static void updateAccountBalances(
        List<Client_Payment__c> payments
    ) {
        Set<Id> saleIds = new Set<Id>();
        for (Client_Payment__c p : payments) {
            if (p.Sale__c != null) saleIds.add(p.Sale__c);
        }
        if (saleIds.isEmpty()) return;

        // @future so Roll-Up Summary recalculates first
        updateAccountBalancesAsync(saleIds);
    }

    @future
    public static void updateAccountBalancesAsync(Set<Id> saleIds) {
        Set<Id> accountIds = new Set<Id>();
        for (Sale__c s : [
            SELECT Client__c FROM Sale__c
            WHERE Id IN :saleIds
            AND Client__c != null
        ]) {
            accountIds.add(s.Client__c);
        }
        if (accountIds.isEmpty()) return;

        Map<Id, Decimal> totalBalance = new Map<Id, Decimal>();
        for (Id accId : accountIds) {
            totalBalance.put(accId, 0);
        }

        for (AggregateResult ar : [
            SELECT Client__c, SUM(Balance_Due__c) total
            FROM Sale__c
            WHERE Client__c IN :accountIds
            AND Balance_Due__c > 0
            AND Order_Status__c != 'Cancelled'
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
}