import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getFundsData from '@salesforce/apex/PersonFundsController.getFundsData';
import saveExpense from '@salesforce/apex/PersonFundsController.saveExpense';
import getExpensesForPerson
    from '@salesforce/apex/PersonFundsController.getExpensesForPerson';
import adjustBalance
    from '@salesforce/apex/PersonFundsController.adjustBalance';

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

    // Balance Adjustment
    @track isAdjOpen   = false;
    @track isAdjSaving = false;
    @track adjPerson   = '';
    @track adjAmount   = '';
    @track adjType     = 'Addition';
    @track adjReason   = '';
    @track adjError    = '';
    @track withdrawalHistory  = [];
    // Profit Distribution
    @track isDistOpen         = false;
    @track isDistSaving       = false;
    @track availableQuarters  = [];
    @track distData           = null;
    @track distAdjusted       = 0;
    @track distDate           = new Date().toISOString().split('T')[0];
    @track distNotes          = '';

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

        return txns
            .sort((a, b) => {
                // Normalise to YYYY-MM-DD for safe string comparison
                const da = a.date ? String(a.date).substring(0, 10) : '0000-00-00';
                const db = b.date ? String(b.date).substring(0, 10) : '0000-00-00';
                return da < db ? 1 : da > db ? -1 : 0; // newest first
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
    get distVikramAmt()  { return ((this.distAdjusted || 0) * 0.45).toFixed(2); }
    get distRohanAmt()   { return ((this.distAdjusted || 0) * 0.45).toFixed(2); }
    get distCompanyAmt() { return ((this.distAdjusted || 0) * 0.10).toFixed(2); }
    get hasWithdrawals() { return (this.withdrawalHistory || []).length > 0; }

    get noPeople() {
        return !this.isLoading && this.personFunds.length === 0;
    }

    // ── Profit Distribution ───────────────────────────
    openDistribution() {
        this.isDistOpen = true;
        this.distData   = null;
        this.distAdjusted = 0;
        this.distDate   = new Date().toISOString().split('T')[0];
        this.distNotes  = '';
        // Load quarters
        getAvailableQuarters()
            .then(qs => { this.availableQuarters = qs || []; })
            .catch(() => {});
        // Load history
        this.loadWithdrawalHistory();
    }

    closeDistribution() { this.isDistOpen = false; }

    loadWithdrawalHistory() {
        getWithdrawalHistory()
            .then(list => {
                this.withdrawalHistory = (list || []).map(w => ({
                    ...w,
                    formattedDate:    this.fmtDate(w.Withdrawal_Date__c),
                    formattedTotal:   this.fmt(w.Adjusted_Profit__c),
                    formattedVikram:  this.fmt(w.Vikram_Amount__c),
                    formattedRohan:   this.fmt(w.Rohan_Amount__c),
                    formattedCompany: this.fmt(w.Company_Reserve__c)
                }));
            })
            .catch(() => {});
    }

    onDistQuarter(e) {
        const quarter = e.target.value;
        if (!quarter) { this.distData = null; return; }
        getQuarterlyProfit({ quarter })
            .then(data => {
                this.distData = {
                    ...data,
                    revenueFormatted:    this.fmt(data.revenue),
                    grossMarginFormatted: this.fmt(data.grossMargin),
                    expensesFormatted:   this.fmt(data.expenses),
                    netProfitFormatted:  this.fmt(data.netProfit),
                    existingVikramFmt:   this.fmt(data.existingVikram),
                    existingRohanFmt:    this.fmt(data.existingRohan),
                    existingCompanyFmt:  this.fmt(data.existingCompany)
                };
                this.distAdjusted = parseFloat(data.netProfit) || 0;
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Error', variant: 'error',
                    message: err.body?.message || 'Could not load profit data.'
                }));
            });
    }

    onDistAdjusted(e) { this.distAdjusted = parseFloat(e.target.value) || 0; }
    onDistDate(e)     { this.distDate  = e.target.value; }
    onDistNotes(e)    { this.distNotes = e.target.value; }

    confirmDistribution() {
        if (!this.distData?.quarter) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Select a quarter', variant: 'warning',
                message: 'Please select a quarter first.'
            }));
            return;
        }
        if (!this.distAdjusted || this.distAdjusted <= 0) {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Invalid amount', variant: 'warning',
                message: 'Profit must be greater than 0.'
            }));
            return;
        }

        this.isDistSaving = true;
        executeDistribution({
            quarter:        this.distData.quarter,
            adjustedProfit: this.distAdjusted,
            withdrawalDate: this.distDate,
            notes:          this.distNotes
        })
        .then(result => {
            this.isDistSaving = false;
            this.isDistOpen   = false;
            this.dispatchEvent(new ShowToastEvent({
                title:   'Profit Distributed! 🎉',
                variant: 'success',
                message: 'Vikram: ₹' + result.vikramAmt +
                         ' | Rohan: ₹' + result.rohanAmt +
                         ' | Company: ₹' + result.companyAmt
            }));
            return refreshApex(this.wiredResult);
        })
        .catch(err => {
            this.isDistSaving = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error', variant: 'error',
                message: err.body?.message || 'Distribution failed.'
            }));
        });
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
        this.adjType    = 'Addition';
        this.adjReason  = '';
        this.adjError   = '';
        this.isAdjOpen  = true;
    }
    closeAdjust() { this.isAdjOpen = false; }

    onAdjPerson(e)  { this.adjPerson = e.target.value; }
    onAdjAmount(e)  { this.adjAmount = e.target.value; }
    onAdjType(e)    { this.adjType   = e.currentTarget.dataset.val; }
    onAdjReason(e)  { this.adjReason = e.target.value; }

    handleAdjustSave() {
        this.adjError = '';
        if (!this.adjPerson) {
            this.adjError = 'Select a person.'; return;
        }
        if (!this.adjAmount || parseFloat(this.adjAmount) <= 0) {
            this.adjError = 'Enter a valid amount.'; return;
        }
        if (!this.adjReason.trim()) {
            this.adjError = 'Enter a reason.'; return;
        }

        this.isAdjSaving = true;
        adjustBalance({
            personName:     this.adjPerson,
            amount:         parseFloat(this.adjAmount),
            adjustmentType: this.adjType,
            reason:         this.adjReason
        })
        .then(() => {
            this.isAdjSaving = false;
            this.isAdjOpen   = false;
            const sign = this.adjType === 'Addition' ? '+' : '-';
            this.dispatchEvent(new ShowToastEvent({
                title:   'Balance Adjusted ✓',
                variant: 'success',
                message: sign + '₹' + this.adjAmount +
                         ' applied to ' + this.adjPerson
            }));
            return refreshApex(this.wiredResult);
        })
        .catch(err => {
            this.isAdjSaving = false;
            this.adjError = err.body?.message || 'Adjustment failed.';
        });
    }
}