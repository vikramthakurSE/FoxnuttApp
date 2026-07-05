public class PurchaseHelper {

    // BEFORE INSERT — derive Quarter from Order Date
    public static void setQuarter(List<Purchase__c> purchases) {
        for (Purchase__c p : purchases) {
            if (p.Order_Date__c != null) {
                p.Quarter__c = getQuarterFromDate(p.Order_Date__c);
            }
        }
    }

    // AFTER INSERT — generate Unique Order Code
    // Format: O{PurchaseNumber}-{Quarter} e.g. OPUR-0001-Qtr2_2025
    public static void setUniqueOrderCode(List<Purchase__c> purchases) {
    Set<Id> purchaseIds = new Set<Id>();
    for (Purchase__c p : purchases) {
        if (p.Name != null && p.Quarter__c != null) {
            purchaseIds.add(p.Id);
        }
    }
    if (!purchaseIds.isEmpty()) {
        setUniqueOrderCodeAsync(purchaseIds);
    }
}

    @future
    private static void setUniqueOrderCodeAsync(Set<Id> purchaseIds) {
        List<Purchase__c> toUpdate = new List<Purchase__c>();
        for (Purchase__c p : [
            SELECT Id, Name, Quarter__c, Unique_Order_Code__c
            FROM Purchase__c WHERE Id IN :purchaseIds
        ]) {
            String code = p.Name + '-' + p.Quarter__c;
            if (p.Unique_Order_Code__c != code) {
                toUpdate.add(new Purchase__c(
                    Id = p.Id,
                    Unique_Order_Code__c = code
                ));
            }
        }
        if (!toUpdate.isEmpty()) update toUpdate;
    }

    // PRIVATE: derive quarter string from date
    private static String getQuarterFromDate(Date d) {
        Integer m = d.month();
        Integer y = d.year();
        if (m <= 3)  return 'Qtr1_' + y;
        if (m <= 6)  return 'Qtr2_' + y;
        if (m <= 9)  return 'Qtr3_' + y;
        return 'Qtr4_' + y;
    }
}