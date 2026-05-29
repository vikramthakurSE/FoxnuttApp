import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getFundsData from '@salesforce/apex/PersonFundsController.getFundsData';
import saveExpense from '@salesforce/apex/PersonFundsController.saveExpense';
import getExpensesForPerson
    from '@salesforce/apex/PersonFundsController.getExpensesForPerson';

export default class PersonFundsView extends LightningElement {

    @track isLoading    = true;
    @track personFunds  = [];
    @track expenseTypes = [];
    @track teamMembers  = [];
    wiredResult;

    @track teamAvailable   = '0.00';
    @track teamCollected   = '0.00';
    @track teamMfrPaid     = '0.00';
    @track teamExpenses    = '0.00';
    @track teamLastUpdated = '—';

    _recentPayments    = [];
    _recentMfrPayments = [];
    _recentExpenses    = [];

    @wire(getFundsData)
    wiredData(result) {
        this.wiredResult = result;
        if (result.data) {
            this.isLoading = false;
            this.processData(result.data);
        } else if (result.error) {
            this.isLoading = false;
        }
    }

    processData(data) {
        this.expenseTypes      = data.expenseTypes || [];
        this.teamMembers        = data.teamMembers   || [];
        this._recentPayments    = data.recentPayments    || [];
        this._recentMfrPayments = data.recentMfrPayments || [];
        this._recentExpenses    = data.recentExpenses    || [];
        this._openingBalances   = data.openingBalances   || [];

        // Compute totals from Person_Fund__c records directly
        // so it stays in sync even after manual balance adjustments
        const funds = data.funds || [];
        const totalCollected  = funds.reduce((s, p) => s + (p.Total_Collected__c || 0), 0);
        const totalMfrPaid    = funds.reduce((s, p) => s + (p.Total_Mfr_Paid__c  || 0), 0);
        const totalExpenses   = funds.reduce((s, p) => s + (p.Total_Expenses__c  || 0), 0);
        const totalAvailable  = totalCollected - totalMfrPaid - totalExpenses;

        this.teamCollected   = this.fmt(totalCollected);
        this.teamMfrPaid     = this.fmt(totalMfrPaid);
        this.teamExpenses    = this.fmt(totalExpenses);
        this.teamAvailable   = this.fmt(totalAvailable);
        this.teamLastUpdated = new Date().toLocaleString('en-IN', {
            day: '2-digit', month: 'short',
            hour: '2-digit', minute: '2-digit'
        });

        this.personFunds = (data.funds || []).map(pf => {
            const avail = pf.Available_Funds__c || 0;
            return {
                ...pf,
                initial: pf.Name
                    ? pf.Name.charAt(0).toUpperCase() : '?',
                formattedAvail:
                    this.fmt(avail),
                formattedCollected:
                    this.fmt(pf.Total_Collected__c),
                formattedMfrPaid:
                    this.fmt(pf.Total_Mfr_Paid__c),
                formattedExpenses:
                    this.fmt(pf.Total_Expenses__c),
                availClass: avail >= 0
                    ? 'pc-avail-amt positive'
                    : 'pc-avail-amt negative',
                formattedDate: pf.Last_Updated__c
                    ? new Date(pf.Last_Updated__c)
                        .toLocaleDateString('en-IN', {
                            day: '2-digit', month: 'short',
                            year: '2-digit'
                        })
                    : '—',
                transactions:
                    this.buildTransactions(pf.Name),
                hasTransactions:
                    this.buildTransactions(pf.Name).length > 0
            };
        });
    }

    buildTransactions(name) {
        const txns = [];

        this._recentPayments
            .filter(p => p.Accepted_By__c === name)
            .slice(0, 3)
            .forEach(p => txns.push({
                key:        'cp_' + p.Id,
                icon:       '💰',
                iconClass:  'txn-icon collect-icon',
                title:      (p.Sale__r &&
                             p.Sale__r.Client__r &&
                             p.Sale__r.Client__r.Name)
                            || 'Client Payment',
                meta:       this.fmtDate(p.Payment_Date__c),
                amtDisplay: '+₹' + this.fmt(p.Amount__c),
                amtClass:   'txn-amt positive',
                date:       p.Payment_Date__c
            }));

        this._recentMfrPayments
            .filter(p => p.Paid_By__c === name)
            .slice(0, 3)
            .forEach(p => txns.push({
                key:        'mp_' + p.Id,
                icon:       '🏭',
                iconClass:  'txn-icon mfr-icon',
                title:      (p.Purchase__r &&
                             p.Purchase__r.Supplier__r &&
                             p.Purchase__r.Supplier__r.Name)
                            || 'Mfr Payment',
                meta:       this.fmtDate(p.Payment_Date__c),
                amtDisplay: '-₹' + this.fmt(p.Amount_Paid__c),
                amtClass:   'txn-amt negative',
                date:       p.Payment_Date__c
            }));

        this._recentExpenses
            .filter(e => e.Spent_By__c === name)
            .slice(0, 3)
            .forEach(e => txns.push({
                key:        'ex_' + e.Id,
                icon:       '🧾',
                iconClass:  'txn-icon expense-icon',
                title:      e.Expense_Type__c || 'Expense',
                meta:       this.fmtDate(e.Expense_Date__c) +
                            (e.Description__c
                              ? ' · ' + e.Description__c : ''),
                amtDisplay: '-₹' + this.fmt(e.Amount__c),
                amtClass:   'txn-amt negative',
                date:       e.Expense_Date__c
            }));

        // Opening balance entry — shows funds carried from previous stock
        this._openingBalances
            .filter(ob => ob.person === name)
            .forEach(ob => txns.push({
                key:        'ob_' + name,
                icon:       '🏦',
                iconClass:  'txn-icon opening-icon',
                title:      'Previous stock balance',
                meta:       this.fmtDate(ob.date),
                amtDisplay: '+₹' + this.fmt(ob.amount),
                amtClass:   'txn-amt positive',
                date:       ob.date
            }));

        return txns
            .sort((a, b) => {
                if (!a.date) return 1;
                if (!b.date) return -1;
                return a.date < b.date ? 1 : -1;
            })
            .slice(0, 5);
    }

    fmt(val)  { return (parseFloat(val) || 0).toFixed(2); }
    fmtDate(d) {
        if (!d) return '—';
        return new Date(d + 'T00:00:00')
            .toLocaleDateString('en-IN', {
                day: '2-digit', month: 'short'
            });
    }

    get noPeople() {
        return !this.isLoading && this.personFunds.length === 0;
    }

    // ── Log Expense ────────────────────────────────────────
    @track isExpenseOpen = false;
    @track isExpSaving   = false;
    @track expAmount     = '';
    @track expDate       = new Date().toISOString().split('T')[0];
    @track expType       = '';
    @track expSpentBy    = '';
    @track expDesc       = '';
    @track expenseError  = '';

    get expSaveLabel() {
        return this.isExpSaving ? 'Saving...' : '✓ Save Expense';
    }

    openExpense() {
        this.expAmount    = '';
        this.expDate      = new Date().toISOString().split('T')[0];
        this.expType      = '';
        this.expSpentBy   = '';
        this.expDesc      = '';
        this.expenseError = '';
        this.isExpenseOpen = true;
        this._scrollToTop();
    }

    closeExpense() { this.isExpenseOpen = false; }
    onExpAmount(e)  { this.expAmount  = e.target.value; }
    onExpDate(e)    { this.expDate    = e.target.value; }
    onExpType(e)    { this.expType    = e.target.value; }
    onExpSpentBy(e) { this.expSpentBy = e.target.value; }
    onExpDesc(e)    { this.expDesc    = e.target.value; }

    handleExpenseSave() {
        this.expenseError = '';
        if (!this.expAmount || parseFloat(this.expAmount) <= 0) {
            this.expenseError = 'Enter a valid amount.'; return;
        }
        if (!this.expDate) {
            this.expenseError = 'Select a date.'; return;
        }
        if (!this.expType) {
            this.expenseError = 'Select expense type.'; return;
        }
        if (!this.expSpentBy) {
            this.expenseError = 'Select who spent this.'; return;
        }

        this.isExpSaving = true;

        saveExpense({
            amount:      parseFloat(this.expAmount),
            expenseDate: this.expDate,
            expenseType: this.expType,
            spentBy:     this.expSpentBy,
            description: this.expDesc || ''
        })
        .then(() => {
            this.isExpSaving   = false;
            this.isExpenseOpen = false;
            return refreshApex(this.wiredResult);
        })
        .then(() => {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Expense logged',
                message: '₹' + this.expAmount +
                         ' deducted from ' +
                         this.expSpentBy + '\'s funds.',
                variant: 'success'
            }));
        })
        .catch(err => {
            this.isExpSaving  = false;
            this.expenseError =
                err.body?.message || 'Save failed.';
        });
    }

    // ── Expense History ────────────────────────────────────
    @track isHistoryOpen    = false;
    @track isHistoryLoading = false;
    @track historyPerson    = '';
    @track expenseHistory   = [];

    get noExpenseHistory() {
        return !this.isHistoryLoading &&
               this.expenseHistory.length === 0;
    }

    openHistory(e) {
        this.historyPerson    = e.target.dataset.person;
        this.isHistoryOpen    = true;
        this.isHistoryLoading = true;
        this.expenseHistory   = [];
        this._scrollToTop();

        getExpensesForPerson({ personName: this.historyPerson })
        .then(data => {
            this.isHistoryLoading = false;
            this.expenseHistory   = (data || []).map(exp => ({
                ...exp,
                formattedAmt:  this.fmt(exp.Amount__c),
                formattedDate: this.fmtDate(exp.Expense_Date__c)
            }));
        })
        .catch(() => { this.isHistoryLoading = false; });
    }

    closeHistory() { this.isHistoryOpen = false; }

    _scrollToTop() {
        setTimeout(() => {
            try {
                window.scrollTo({ top: 0, behavior: 'smooth' });
            } catch(e) { /* silent */ }
        }, 50);
    }
}