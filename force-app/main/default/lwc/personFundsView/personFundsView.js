import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getFundsData from '@salesforce/apex/PersonFundsController.getFundsData';
import saveExpense from '@salesforce/apex/PersonFundsController.saveExpense';
import getAvailableQuarters from '@salesforce/apex/PersonFundsController.getAvailableQuarters';
import getQuarterlyFundsData from '@salesforce/apex/PersonFundsController.getQuarterlyFundsData';
import getExpensesForPerson
    from '@salesforce/apex/PersonFundsController.getExpensesForPerson';
import adjustBalance
    from '@salesforce/apex/PersonFundsController.adjustBalance';

export default class PersonFundsView extends LightningElement {

    @track isLoading          = true;
    @track availableQtrs      = [];
    @track selectedQtr        = 'all';
    @track isQtrLoading       = false;
    @track qtrData            = null;
    @track personFunds  = [];
    @track expenseTypes = [];
    @track teamMembers  = [];
    wiredResult;

    @track teamAvailable   = '0.00';
    @track teamCollected   = '0.00';
    @track teamMfrPaid     = '0.00';
    @track teamExpenses    = '0.00';
    @track teamWithdrawn   = '0.00';
    @track teamLastUpdated = '—';

    _recentPayments    = [];
    _recentMfrPayments = [];
    _recentExpenses    = [];

    // Balance Adjustment
    @track isAdjOpen   = false;
    @track isAdjSaving = false;
    @track adjPerson   = '';
    @track adjAmount   = '';
    @track adjReason   = '';
    @track adjNotes    = '';
    @track adjType     = 'Subtraction'; // default for most reasons
    @track adjError    = '';
    @track withdrawalHistory  = [];

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
        this._adjustmentEntries = data.adjustmentEntries || [];

        // Compute totals from Person_Fund__c records directly
        // Must include Total_Withdrawn__c (profit distributions)
        const funds = data.funds || [];
        const totalCollected  = funds.reduce((s, p) => s + (p.Total_Collected__c  || 0), 0);
        const totalMfrPaid    = funds.reduce((s, p) => s + (p.Total_Mfr_Paid__c   || 0), 0);
        const totalExpenses   = funds.reduce((s, p) => s + (p.Total_Expenses__c   || 0), 0);
        const totalWithdrawn  = funds.reduce((s, p) => s + (p.Total_Withdrawn__c  || 0), 0);
        const totalAvailable  = totalCollected - totalMfrPaid - totalExpenses - totalWithdrawn;

        this.teamCollected   = this.fmt(totalCollected);
        this.teamMfrPaid     = this.fmt(totalMfrPaid);
        this.teamExpenses    = this.fmt(totalExpenses);
        this.teamWithdrawn   = this.fmt(totalWithdrawn);
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

        // Collect ALL entries from all sources — no pre-slicing
        // Final sort + slice(5) determines what's shown
        this._recentPayments
            .filter(p => p.Accepted_By__c === name)
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
            .forEach(e => txns.push({
                key:        'ex_' + e.Id,
                icon:       '🧾',
                iconClass:  'txn-icon expense-icon',
                title:      e.Expense_Type__c || 'Expense',
                meta:       this.fmtDate(e.Expense_Date__c) +
                            (e.Notes_Remarks__c
                              ? ' · ' + e.Notes_Remarks__c : ''),
                amtDisplay: '-₹' + this.fmt(e.Amount__c),
                amtClass:   'txn-amt negative',
                date:       e.Expense_Date__c
            }));

        // Opening balance — old date, only shows if no newer activity pushes it out
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

        // Manual balance adjustments
        (this._adjustmentEntries || [])
            .filter(a => a.person === name)
            .forEach((a, i) => {
                const isAdd = a.type === 'Addition';
                txns.push({
                    key:        'adj_' + name + '_' + i,
                    icon:       isAdd ? '⬆️' : '⬇️',
                    iconClass:  isAdd
                                ? 'txn-icon adj-add-icon'
                                : 'txn-icon adj-sub-icon',
                    title:      (isAdd ? 'Balance Added' : 'Balance Deducted'),
                    meta:       this.fmtDate(a.date) +
                                (a.reason ? ' · ' + a.reason : ''),
                    amtDisplay: (isAdd ? '+' : '-') + '₹' + this.fmt(a.amount),
                    amtClass:   isAdd ? 'txn-amt positive' : 'txn-amt negative',
                    date:       a.date
                });
            });

        // Sort ALL entries newest first, then take top 5
        return txns
            .sort((a, b) => {
                const da = a.date ? String(a.date).substring(0, 10) : '0000-00-00';
                const db = b.date ? String(b.date).substring(0, 10) : '0000-00-00';
                return da < db ? 1 : da > db ? -1 : 0;
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

    // Distribution computed getters
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
    // View All Activity
    @track isActivityOpen    = false;
    @track isActivityLoading = false;
    @track activityPerson    = '';
    @track allActivityTxns   = [];
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

    // ── View All Activity ───────────────────────────────────────────────
    get noActivityHistory() {
        return !this.isActivityLoading && this.allActivityTxns.length === 0;
    }

    openActivity(e) {
        const person = e.currentTarget.dataset.person;
        this.activityPerson    = person;
        this.isActivityOpen    = true;
        this.isActivityLoading = true;

        // Build full transaction list — same as buildTransactions but no slice limit
        try {
            const txns = [];

            this._recentPayments
                .filter(p => p.Accepted_By__c === person)
                .forEach(p => txns.push({
                    key:        'cp_' + p.Id,
                    icon:       '💰',
                    iconClass:  'txn-icon collect-icon',
                    title:      (p.Sale__r?.Client__r?.Name) || 'Client Payment',
                    meta:       this.fmtDate(p.Payment_Date__c),
                    amtDisplay: '+₹' + this.fmt(p.Amount__c),
                    amtClass:   'txn-amt positive',
                    date:       p.Payment_Date__c
                }));

            this._recentMfrPayments
                .filter(p => p.Paid_By__c === person)
                .forEach(p => txns.push({
                    key:        'mp_' + p.Id,
                    icon:       '🏭',
                    iconClass:  'txn-icon mfr-icon',
                    title:      (p.Purchase__r?.Supplier__r?.Name) || 'Mfr Payment',
                    meta:       this.fmtDate(p.Payment_Date__c),
                    amtDisplay: '-₹' + this.fmt(p.Amount_Paid__c),
                    amtClass:   'txn-amt negative',
                    date:       p.Payment_Date__c
                }));

            this._recentExpenses
                .filter(e => e.Spent_By__c === person)
                .forEach(e => txns.push({
                    key:        'ex_' + e.Id,
                    icon:       '🧾',
                    iconClass:  'txn-icon expense-icon',
                    title:      e.Expense_Type__c || 'Expense',
                    meta:       this.fmtDate(e.Expense_Date__c) +
                                (e.Notes_Remarks__c ? ' · ' + e.Notes_Remarks__c : ''),
                    amtDisplay: '-₹' + this.fmt(e.Amount__c),
                    amtClass:   'txn-amt negative',
                    date:       e.Expense_Date__c
                }));

            (this._openingBalances || [])
                .filter(ob => ob.person === person)
                .forEach(ob => txns.push({
                    key:        'ob_' + person,
                    icon:       '🏦',
                    iconClass:  'txn-icon opening-icon',
                    title:      'Previous stock balance',
                    meta:       this.fmtDate(ob.date),
                    amtDisplay: '+₹' + this.fmt(ob.amount),
                    amtClass:   'txn-amt positive',
                    date:       ob.date
                }));

            (this._adjustmentEntries || [])
                .filter(a => a.person === person)
                .forEach((a, i) => {
                    const isAdd = a.type === 'Addition';
                    txns.push({
                        key:        'adj_' + person + '_' + i,
                        icon:       isAdd ? '⬆️' : '⬇️',
                        iconClass:  isAdd ? 'txn-icon adj-add-icon'
                                         : 'txn-icon adj-sub-icon',
                        title:      isAdd ? 'Balance Added' : 'Balance Deducted',
                        meta:       this.fmtDate(a.date) +
                                    (a.reason ? ' · ' + a.reason : ''),
                        amtDisplay: (isAdd ? '+' : '-') + '₹' + this.fmt(a.amount),
                        amtClass:   isAdd ? 'txn-amt positive' : 'txn-amt negative',
                        date:       a.date
                    });
                });

            // Sort newest first — NO slice limit
            this.allActivityTxns = txns.sort((a, b) => {
                const da = a.date ? String(a.date).substring(0, 10) : '0000-00-00';
                const db = b.date ? String(b.date).substring(0, 10) : '0000-00-00';
                return da < db ? 1 : da > db ? -1 : 0;
            });

            this.isActivityLoading = false;
        } catch(err) {
            this.isActivityLoading = false;
        }
    }

    closeActivity() { this.isActivityOpen = false; }

    // ── Quarter Selector ────────────────────────────────────────────────
    get isAllTime() { return this.selectedQtr === 'all'; }

    get quarterLabel() {
        if (this.selectedQtr === 'all') return 'All Time';
        const parts  = this.selectedQtr.split('_');
        const qNum   = parts[0].replace('Qtr', '');
        const yr     = parts[1];
        const months = { '1':'Jan–Mar', '2':'Apr–Jun', '3':'Jul–Sep', '4':'Oct–Dec' };
        return 'Q' + qNum + ' ' + yr + '  (' + (months[qNum] || '') + ')';
    }

    get displayedTeamCollected() {
        return this.qtrData ? this.fmt(this.qtrData.teamCollected) : this.teamCollected;
    }
    get displayedTeamMfrPaid() {
        return this.qtrData ? this.fmt(this.qtrData.teamMfrPaid)  : this.teamMfrPaid;
    }
    get displayedTeamExpenses() {
        return this.qtrData ? this.fmt(this.qtrData.teamExpenses) : this.teamExpenses;
    }
    get displayedTeamAvailable() {
        return this.qtrData ? this.fmt(this.qtrData.teamNetFlow)  : this.teamAvailable;
    }

    get quarterPersonCards() {
        if (!this.qtrData) return [];
        return (this.qtrData.personSummaries || []).map(p => ({
            ...p,
            initial:     p.name ? p.name.charAt(0).toUpperCase() : '?',
            fmtCollected : this.fmt(p.collected),
            fmtMfrPaid   : this.fmt(p.mfrPaid),
            fmtExpenses  : this.fmt(p.expenses),
            fmtNetFlow   : this.fmt(Math.abs(p.netFlow)),
            netFlowClass : parseFloat(p.netFlow) >= 0
                           ? 'pc-avail-amt positive'
                           : 'pc-avail-amt negative'
        }));
    }

    get qtrRecentPayments()    { return this.qtrData ? this.qtrData.recentPayments    || [] : this._recentPayments; }
    get qtrRecentMfrPayments() { return this.qtrData ? this.qtrData.recentMfrPayments || [] : this._recentMfrPayments; }
    get qtrRecentExpenses()    { return this.qtrData ? this.qtrData.recentExpenses    || [] : this._recentExpenses; }

    onQuarterChange(e) {
        const val = e.target.value;
        this.selectedQtr = val;
        if (val === 'all') {
            this.qtrData = null;
            return;
        }
        this.isQtrLoading = true;
        getQuarterlyFundsData({ quarter: val })
            .then(data => {
                this.qtrData      = data;
                this.isQtrLoading = false;
            })
            .catch(() => { this.isQtrLoading = false; });
    }

    connectedCallback() {
        getAvailableQuarters()
            .then(qtrs => { this.availableQtrs = qtrs || []; })
            .catch(() => {});
    }

    _scrollToTop() {
        setTimeout(() => {
            try {
                window.scrollTo({ top: 0, behavior: 'smooth' });
            } catch(e) { /* silent */ }
        }, 50);
    }

    // Adjust balance toggle classes
    get addBtnClass() {
        return this.adjType === 'Addition'
            ? 'adj-toggle-btn adj-active-add'
            : 'adj-toggle-btn';
    }
    get subBtnClass() {
        return this.adjType === 'Subtraction'
            ? 'adj-toggle-btn adj-active-sub'
            : 'adj-toggle-btn';
    }

    // ── Adjust Balance ──────────────────────────────────────────────────
    openAdjust() {
        this.adjPerson  = '';
        this.adjAmount  = '';
        this.adjReason  = '';
        this.adjNotes   = '';
        this.adjType    = 'Subtraction';
        this.adjError   = '';
        this.isAdjOpen  = true;
    }
    closeAdjust() { this.isAdjOpen = false; }

    onAdjPerson(e)  { this.adjPerson = e.target.value; this.adjError = ''; }
    onAdjAmount(e)  { this.adjAmount = e.target.value; }
    onAdjReason(e)  {
        this.adjReason = e.target.value;
        this.adjError  = '';
        // Balance Adjustment needs type toggle; others are always subtraction
        if (this.adjReason === 'Balance Adjustment') {
            this.adjType = 'Addition';
        } else {
            this.adjType = 'Subtraction';
        }
    }
    onAdjNotes(e)   { this.adjNotes  = e.target.value; }
    onAdjType(e)    { this.adjType   = e.currentTarget.dataset.val; }

    // Show type toggle only for Balance Adjustment
    get showTypeToggle() { return this.adjReason === 'Balance Adjustment'; }

    get addBtnClass() {
        return this.adjType === 'Addition'
            ? 'adj-toggle-btn adj-active-add' : 'adj-toggle-btn';
    }
    get subBtnClass() {
        return this.adjType === 'Subtraction'
            ? 'adj-toggle-btn adj-active-sub' : 'adj-toggle-btn';
    }

    handleAdjustSave() {
        this.adjError = '';

        if (!this.adjPerson) {
            this.adjError = 'Select a person.'; return;
        }
        if (!this.adjReason) {
            this.adjError = 'Select a reason.'; return;
        }
        if (!this.adjAmount || parseFloat(this.adjAmount) <= 0) {
            this.adjError = 'Enter a valid amount.'; return;
        }

        // Validate: cannot transfer to yourself
        if ((this.adjReason === 'Transferred to Vikram' && this.adjPerson === 'Vikram') ||
            (this.adjReason === 'Transferred to Rohan'  && this.adjPerson === 'Rohan')) {
            this.adjError = 'Cannot transfer to yourself.'; return;
        }

        this.isAdjSaving = true;
        adjustBalance({
            personName:     this.adjPerson,
            amount:         parseFloat(this.adjAmount),
            adjustmentType: this.adjType,
            reason:         this.adjReason,
            notes:          this.adjNotes || ''
        })
        .then(() => {
            this.isAdjSaving = false;
            this.isAdjOpen   = false;
            let msg = '';
            if (this.adjReason === 'Transferred to Vikram' || this.adjReason === 'Transferred to Rohan') {
                const toName = this.adjReason === 'Transferred to Vikram' ? 'Vikram' : 'Rohan';
                msg = '₹' + this.adjAmount + ' transferred to ' + toName;
            } else if (this.adjReason === 'Profit Withdrawal') {
                msg = '₹' + this.adjAmount + ' profit withdrawn for ' + this.adjPerson;
            } else {
                const sign = this.adjType === 'Addition' ? '+' : '-';
                msg = sign + '₹' + this.adjAmount + ' adjusted for ' + this.adjPerson;
            }
            this.dispatchEvent(new ShowToastEvent({
                title: 'Done ✓', variant: 'success', message: msg
            }));
            return refreshApex(this.wiredResult);
        })
        .catch(err => {
            this.isAdjSaving = false;
            this.adjError = err.body?.message || 'Failed. Try again.';
        });
    }
}