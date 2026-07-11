import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import getAccountData   from '@salesforce/apex/AccountClientController.getAccountData';
import savePayment      from '@salesforce/apex/AccountClientController.savePayment';
import getFollowUpStatus from '@salesforce/apex/AccountClientController.getFollowUpStatus';
import saveFollowUp      from '@salesforce/apex/AccountClientController.saveFollowUp';
import updateSaleStatus from '@salesforce/apex/AccountClientController.updateSaleStatus';
import getInventory     from '@salesforce/apex/QuickSaleController.getInventory';
import getPicklistValues from '@salesforce/apex/QuickSaleController.getPicklistValues';
import saveSale         from '@salesforce/apex/QuickSaleController.saveSale';

import NAME_FIELD    from '@salesforce/schema/Account.Name';
import PHONE_FIELD   from '@salesforce/schema/Account.Phone';
import TYPE_FIELD    from '@salesforce/schema/Account.Type';
import AREA_FIELD    from '@salesforce/schema/Account.Area__c';
import CONTACT_FIELD from '@salesforce/schema/Account.Contact_Person__c';
import GSTIN_FIELD   from '@salesforce/schema/Account.GSTIN__c';
import MAP_FIELD     from '@salesforce/schema/Account.Map_Location__c';
import MANAGER_FIELD from '@salesforce/schema/Account.Regional_Manager__c';

const FIELDS = [
    NAME_FIELD, PHONE_FIELD, TYPE_FIELD, AREA_FIELD,
    CONTACT_FIELD, GSTIN_FIELD, MAP_FIELD, MANAGER_FIELD
];

export default class AccountClientView extends NavigationMixin(LightningElement) {
    @api recordId;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    accountRecord;

    get accountName()    { return getFieldValue(this.accountRecord.data, NAME_FIELD) || ''; }
    get phone()          { return getFieldValue(this.accountRecord.data, PHONE_FIELD); }
    get phoneLink()      { return 'tel:' + this.phone; }
    get accountType()    { return getFieldValue(this.accountRecord.data, TYPE_FIELD) || 'Client'; }
    get area()           { return getFieldValue(this.accountRecord.data, AREA_FIELD); }
    get contactPerson()  { return getFieldValue(this.accountRecord.data, CONTACT_FIELD); }
    get gstin()          { return getFieldValue(this.accountRecord.data, GSTIN_FIELD); }
    get mapLocation()    { return getFieldValue(this.accountRecord.data, MAP_FIELD); }
    get regionalManager(){ return getFieldValue(this.accountRecord.data, MANAGER_FIELD); }

    // Balance calculated live from sales — never stale
    get accountBalance() {
        return this.sales
            .filter(s => s.Order_Status__c === 'Delivered')
            .reduce((s, sale) => s + (parseFloat(sale.Balance_Due__c) || 0), 0)
            .toFixed(2);
    }
    get hasBalance() {
        return this.sales.some(s =>
            s.Order_Status__c === 'Delivered' && (s.Balance_Due__c || 0) > 0
        );
    }

    // ── Sales wire ─────────────────────────────────────────
    @track sales    = [];
    @track isLoading = true;
    wiredSalesResult;

    @wire(getAccountData, { accountId: '$recordId' })
    wiredSales(result) {
        this.wiredSalesResult = result;
        if (result.data) {
            this.isLoading = false;
            this.sales = this.processSales(result.data);
        } else if (result.error) {
            this.isLoading = false;
        }
    }

    connectedCallback() {
        this._visHandler = () => {
            if (!document.hidden && this.wiredSalesResult) refreshApex(this.wiredSalesResult);
        };
        document.addEventListener('visibilitychange', this._visHandler);
        this.loadFollowUpStatus();
    }
    disconnectedCallback() {
        document.removeEventListener('visibilitychange', this._visHandler);
    }

    loadFollowUpStatus() {
        if (!this.recordId) return;
        getFollowUpStatus({ accountId: this.recordId })
            .then(result => {
                this.followUp        = result.followUp      || false;
                this.followUpNotes   = result.followUpNotes || '';
                this.followUpHistory = result.followUpHistory || '';
                this.followUpDate    = result.followUpDate
                    ? new Date(result.followUpDate + 'T00:00:00')
                        .toLocaleDateString('en-IN', {
                            day: '2-digit', month: 'short', year: '2-digit'
                        })
                    : '';
            })
            .catch(() => {});
    }

    onFollowUpToggle()   { this.followUp = !this.followUp; }
    onFollowUpNotes(e)   { this.followUpNotes = e.target.value; }

    saveFollowUpHandler() {
        const nextFollowUp = !this.followUp;
        this.isFollowUpSaving = true;
        saveFollowUp({
            accountId: this.recordId,
            followUp:  nextFollowUp,
            notes:     this.followUpNotes || ''
        })
        .then(() => {
            this.isFollowUpSaving = false;
            this.followUp = nextFollowUp;
            this.dispatchEvent(new ShowToastEvent({
                title:   nextFollowUp ? 'Follow Up Marked ✓' : 'Follow Up Cleared',
                message: nextFollowUp
                    ? 'Reminders paused for 1 week.'
                    : 'Daily reminders will resume.',
                variant: 'success'
            }));
            this.loadFollowUpStatus();
        })
        .catch(err => {
            this.isFollowUpSaving = false;
            this.dispatchEvent(new ShowToastEvent({
                title: 'Error', variant: 'error',
                message: err.body?.message || 'Could not save.'
            }));
        });
    }

    get followUpBtnLabel() {
        return this.isFollowUpSaving ? 'Saving...'
             : this.followUp ? '✓ Followed Up'
             : 'Mark as Followed Up';
    }
    get followUpBtnClass() {
        return this.followUp
            ? 'followup-btn followup-active'
            : 'followup-btn';
    }
    get hasFollowUpHistory() {
        return this.followUpHistory && this.followUpHistory.length > 0;
    }
    get followUpHistoryLines() {
        if (!this.followUpHistory) return [];
        return this.followUpHistory.split('\n')
            .filter(l => l.trim().length > 0)
            .map((l, i) => ({ key: i, text: l }));
    }

    processSales(rawSales) {
        return rawSales.map(s => {
            const os  = s.Order_Status__c || '';
            const ps  = s.Payment_Status__c || '';

            // ── Financial breakdown ───────────────────────────────────────
            // lineTotal = sum of qty × rate (pre-GST)
            const lineItems = (s.Sale_Line_Items__r || []).map(li => ({
                ...li,
                formattedTotal: ((li.Quantity__c || 0) * (li.Rate_Per_Kg__c || 0)).toFixed(2)
            }));
            const lineTotal   = lineItems.reduce(
                (sum, li) => sum + (li.Quantity__c || 0) * (li.Rate_Per_Kg__c || 0), 0
            );

            // invoiceTotal = Total_Revenue__c (includes GST)
            const invoiceTotal = s.Total_Revenue__c || 0;

            // gstAmount = difference between invoice and line items
            const gstAmount = Math.max(0, invoiceTotal - lineTotal);
            const hasGst    = gstAmount > 0.01;
            const gstPct    = lineTotal > 0
                ? ((gstAmount / lineTotal) * 100).toFixed(0) : 0;

            // CD
            const cdTotal = s.Total_CD_Amount__c || 0;
            const hasCd   = cdTotal > 0;

            // Net receivable = invoiceTotal - CD
            const netReceivable = invoiceTotal - cdTotal;

            // Cash collected = Total_Collected__c (sums Settlement_Amount__c)
            // minus CD since Settlement includes CD to zero the balance
            const settlementCol = s.Total_Collected__c || 0;
            const cashCollected = settlementCol - cdTotal;

            // Balance due — only for Delivered sales
            const rawBal = s.Balance_Due__c || 0;
            const bal    = os === 'Delivered' ? rawBal : 0;

            let statusClass = 'pay-badge ';
            if (os === 'Cancelled')           statusClass += 'badge-cancelled';
            else if (ps === 'Fully Paid')     statusClass += 'badge-paid';
            else if (ps === 'Partially Paid') statusClass += 'badge-partial';
            else                              statusClass += 'badge-unpaid';

            let orderStatusClass = 'order-badge ';
            if (os === 'Delivered')              orderStatusClass += 'obadge-delivered';
            else if (os === 'Out for Delivery')  orderStatusClass += 'obadge-transit';
            else if (os === 'Confirmed')         orderStatusClass += 'obadge-confirmed';
            else if (os === 'Cancelled')         orderStatusClass += 'obadge-cancelled';
            else                                 orderStatusClass += 'obadge-default';

            const statusOrder = ['Confirmed', 'Out for Delivery', 'Delivered', 'Cancelled'];
            const currentIdx  = statusOrder.indexOf(os);
            const isLocked    = os === 'Delivered' || os === 'Cancelled';

            const btnClass = (btnStatus) => {
                const btnIdx    = statusOrder.indexOf(btnStatus);
                const isCurrent = btnStatus === os;
                const isPast    = btnIdx < currentIdx;
                const isDisabled = isLocked || isPast || isCurrent;
                let cls = 'sc-btn ';
                if (btnStatus === 'Confirmed')             cls += 'sc-confirmed';
                else if (btnStatus === 'Out for Delivery') cls += 'sc-transit';
                else if (btnStatus === 'Delivered')        cls += 'sc-delivered';
                else if (btnStatus === 'Cancelled')        cls += 'sc-cancelled';
                if (isCurrent) cls += ' sc-active';
                if (isDisabled) cls += ' sc-disabled';
                return cls;
            };

            const payments = (s.Client_Payments__r || []).map(p => ({
                ...p,
                formattedAmount: (p.Amount__c || 0).toFixed(2),
                formattedDate: p.Payment_Date__c
                    ? new Date(p.Payment_Date__c + 'T00:00:00')
                        .toLocaleDateString('en-IN', { day:'2-digit', month:'short' })
                    : '—'
            }));

            const saleDate = s.Sale_Date__c
                ? new Date(s.Sale_Date__c + 'T00:00:00')
                    .toLocaleDateString('en-IN', { day:'2-digit', month:'short', year:'2-digit' })
                : '—';

            return {
                ...s,
                Balance_Due__c:      bal,
                isExpanded:          false,
                formattedDate:       saleDate,
                expectedDeliveryDate: s.Expected_Delivery_Date__c
                    ? new Date(s.Expected_Delivery_Date__c + 'T00:00:00')
                        .toLocaleDateString('en-IN', { day:'2-digit', month:'short', year:'2-digit' })
                    : null,
                // Financial breakdown
                lineTotal:           lineTotal.toFixed(2),
                gstAmount:           gstAmount.toFixed(2),
                gstPct,
                hasGst,
                invoiceTotal:        invoiceTotal.toFixed(2),
                hasCd,
                cdTotal:             cdTotal.toFixed(2),
                netReceivable:       netReceivable.toFixed(2),
                cashCollected:       Math.max(0, cashCollected).toFixed(2),
                formattedRevenue:    netReceivable.toFixed(2),
                formattedCollected:  Math.max(0, cashCollected).toFixed(2),
                formattedBalance:    bal.toFixed(2),
                statusClass,
                orderStatusClass,
                balanceClass:        bal > 0 ? 'fin-val red' : 'fin-val green',
                chevronClass:        'sale-chevron',
                lineItems,
                hasLineItems:        lineItems.length > 0,
                payments,
                hasPayments:         payments.length > 0,
                isCancelled:         os === 'Cancelled',
                isNotDelivered:      os !== 'Delivered' && os !== 'Cancelled',
                statusDisplay:       os === 'Cancelled' ? 'Cancelled' : ps,
                statusLocked:        isLocked,
                btnClassConfirmed:   btnClass('Confirmed'),
                btnClassTransit:   btnClass('Out for Delivery'),
                btnClassDelivered: btnClass('Delivered'),
                btnClassCancelled: btnClass('Cancelled')
            };
        });
    }

    get totalSalesCount() { return this.sales.length; }
    get isEmpty() { return !this.isLoading && this.sales.length === 0; }

    toggleSale(e) {
        const id = e.currentTarget.dataset.id;
        this.sales = this.sales.map(s => {
            if (s.Id === id) {
                const expanded = !s.isExpanded;
                return { ...s, isExpanded: expanded, chevronClass: expanded ? 'sale-chevron rotated' : 'sale-chevron' };
            }
            return s;
        });
    }

    viewSale(e) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: e.currentTarget.dataset.id, actionName: 'view' }
        });
    }

    // ── Status update ──────────────────────────────────────
    updateStatus(e) {
        const saleId    = e.currentTarget.dataset.id;
        const newStatus = e.currentTarget.dataset.status;
        const sale      = this.sales.find(s => s.Id === saleId);
        if (!sale) return;
        if (sale.Order_Status__c === newStatus) return;

        // Block if already Delivered or Cancelled
        if (sale.statusLocked) {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Status Locked',
                message: 'A ' + sale.Order_Status__c + ' order cannot be changed.',
                variant: 'warning'
            }));
            return;
        }

        // Block going backwards in the flow
        const order = ['Confirmed', 'Out for Delivery', 'Delivered', 'Cancelled'];
        const currentIdx = order.indexOf(sale.Order_Status__c);
        const newIdx     = order.indexOf(newStatus);
        if (newIdx <= currentIdx) {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Cannot Go Back',
                message: 'Status can only move forward: Confirmed → Out for Delivery → Delivered.',
                variant: 'warning'
            }));
            return;
        }

        // Optimistic update
        this.sales = this.sales.map(s => {
            if (s.Id !== saleId) return s;
            let orderStatusClass = 'order-badge ';
            if (newStatus === 'Delivered')           orderStatusClass += 'obadge-delivered';
            else if (newStatus === 'Out for Delivery') orderStatusClass += 'obadge-transit';
            else if (newStatus === 'Confirmed')      orderStatusClass += 'obadge-confirmed';
            else if (newStatus === 'Cancelled')      orderStatusClass += 'obadge-cancelled';
            return { ...s, Order_Status__c: newStatus, orderStatusClass };
        });

        updateSaleStatus({ saleId, status: newStatus })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Status Updated', message: 'Sale is now ' + newStatus + '.', variant: 'success'
                }));
                return refreshApex(this.wiredSalesResult);
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Update Failed', message: err.body?.message || 'Could not update status.', variant: 'error'
                }));
                refreshApex(this.wiredSalesResult);
            });
    }

    // ── Log Payment Modal ──────────────────────────────────
    @track isPaymentOpen   = false;
    @track isPaymentSaving = false;
    @track paymentSaleId   = '';
    @track paymentSaleName = '';
    @track paymentBalance  = '0.00';
    @track paymentAmount   = '';
    @track paymentDate     = new Date().toISOString().split('T')[0];
    @track paymentMode     = 'Cash';
    @track paymentBy       = '';
    @track paymentRef      = '';
    @track paymentError    = '';
    // Follow Up
    @track followUp          = false;
    @track followUpNotes     = '';
    @track followUpDate      = '';
    @track followUpHistory   = '';
    @track isFollowUpSaving  = false;
    @track cdPercentage    = '';
    @track cdAmount        = '0.00';
    @track cashToCollect   = '0.00';

    get paymentModes() { return ['Cash', 'UPI', 'Cheque', 'NEFT/RTGS']; }
    get paymentSaveLabel() { return this.isPaymentSaving ? 'Saving...' : '✓ Record Payment'; }

    logPayment(e) {
        const saleId = e.currentTarget.dataset.id;
        // Look up sale directly from processed array — most reliable approach
        const sale = this.sales.find(s => s.Id === saleId);
        if (!sale) return;

        // Validate status before opening modal
        if (sale.Order_Status__c !== 'Delivered') {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Mark as Delivered First',
                message: 'Change the order status to Delivered before logging a payment.',
                variant: 'warning',
                mode:    'sticky'
            }));
            return;
        }

        const bal = parseFloat(sale.Balance_Due__c) || 0;
        this.paymentSaleId   = saleId;
        this.paymentSaleName = sale.Name;
        this.paymentBalance  = bal.toFixed(2);
        this.paymentAmount   = bal > 0 ? bal.toFixed(2) : '';
        this.paymentDate     = new Date().toISOString().split('T')[0];
        this.paymentMode     = 'Cash';
        this.paymentBy       = '';
        this.paymentRef      = '';
        this.paymentError    = '';
        this.cdPercentage    = '';
        this.cdAmount        = '0.00';
        this.cashToCollect   = bal > 0 ? bal.toFixed(2) : '0.00';
        this.isPaymentOpen   = true;
        this._scrollToTop();
    }

    closePaymentModal() { this.isPaymentOpen = false; }
    onPaymentDate(e)    { this.paymentDate   = e.target.value; }
    onPaymentAmount(e)  { this.paymentAmount = e.target.value; this._recalcCd(); }
    onPaymentMode(e)    { this.paymentMode   = e.target.value; }
    onPaymentBy(e)      { this.paymentBy     = e.target.value; }
    onPaymentRef(e)     { this.paymentRef    = e.target.value; }

    // Settling Amount (paymentAmount) = full amount being cleared
    // against the balance, INCLUDING the discount given.
    // CD % is applied on this settling amount.
    // Cash to actually collect = Settling Amount - CD Amount.
    onCdPercentage(e) {
        this.cdPercentage = e.target.value;
        this._recalcCd();
    }

    _recalcCd() {
        const settling = parseFloat(this.paymentAmount) || 0;
        const pct       = parseFloat(this.cdPercentage)  || 0;
        const cd        = +(settling * pct / 100).toFixed(2);
        this.cdAmount      = cd.toFixed(2);
        this.cashToCollect = Math.max(0, settling - cd).toFixed(2);
    }

    handlePaymentSave() {
        this.paymentError = '';
        if (!this.paymentAmount || parseFloat(this.paymentAmount) <= 0) {
            this.paymentError = 'Enter a valid amount.'; return;
        }
        if (!this.paymentDate) { this.paymentError = 'Select payment date.'; return; }
        if (!this.paymentBy)   { this.paymentError = 'Select who collected the payment.'; return; }

        this.isPaymentSaving = true;
        savePayment({
            saleId:       this.paymentSaleId,
            // Amount__c stores ACTUAL CASH collected (settling − CD)
            amount:       parseFloat(this.cashToCollect),
            paymentDate:  this.paymentDate,
            mode:         this.paymentMode,
            acceptedBy:   this.paymentBy,
            reference:    this.paymentRef || '',
            cdPercentage: parseFloat(this.cdPercentage) || 0,
            cdAmount:     parseFloat(this.cdAmount) || 0
        })
        .then(() => {
            this.isPaymentSaving = false;
            this.isPaymentOpen   = false;
            return refreshApex(this.wiredSalesResult);
        })
        .then(() => {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Payment Recorded',
                message: parseFloat(this.cdAmount) > 0
                    ? '₹' + this.cashToCollect + ' collected (₹' +
                      this.cdAmount + ' CD applied, ₹' +
                      this.paymentAmount + ' settled)'
                    : '₹' + this.paymentAmount + ' logged.',
                variant: 'success'
            }));
        })
        .catch(err => {
            this.isPaymentSaving = false;
            this.paymentError = err.body?.message || 'Save failed.';
        });
    }

    // ── New Sale Modal ─────────────────────────────────────
    @track isSaleOpen       = false;
    @track isSaving         = false;
    @track saleError        = '';
    @track saleDate              = new Date().toISOString().split('T')[0];
    @track expectedDeliveryDate  = '';
    @track orderStatus           = 'Confirmed';
    @track saleManager      = '';
    @track lineItems        = [];
    @track lineItemCounter  = 0;
    @track brandOptions     = [];
    @track packetTypeOptions= [];
    @track statusOptions    = [];
    @track managerOptions   = [];
    @track inventory        = [];

    @wire(getInventory)
    wiredInventory({ data }) {
        if (data) {
            const items = data.inventory || [];
            this.inventory = items.map(inv => ({
                ...inv,
                stockPillClass: (inv.available || 0) <= 0   ? 'stock-pill sp-empty'
                              : (inv.available || 0) < 10   ? 'stock-pill sp-low'
                              : 'stock-pill sp-ok'
            }));
        }
    }

    @wire(getPicklistValues)
    wiredPicklists({ data }) {
        if (data) {
            this.brandOptions      = data.brands    || [];
            this.packetTypeOptions = data.packetTypes|| [];
            this.statusOptions     = data.statuses  || [];
            this.managerOptions    = data.managers  || [];
        }
    }

    get saveLabel()    { return this.isSaving ? 'Saving...' : '✓ Save Sale'; }
    get hasLineItems() { return this.lineItems.length > 0; }
    get grandTotal() {
        return this.lineItems.reduce((s, li) => s + parseFloat(li.lineTotal || 0), 0).toFixed(2);
    }

    openSaleModal()  { this.resetSaleForm(); this.isSaleOpen = true; this._scrollToTop(); }
    closeSaleModal() { this.isSaleOpen = false; this.saleError = ''; }

    resetSaleForm() {
        this.saleDate = new Date().toISOString().split('T')[0];
        this.expectedDeliveryDate = '';
        this.orderStatus = 'Confirmed'; this.saleManager = '';
        this.lineItems = []; this.lineItemCounter = 0; this.saleError = '';
    }

    onSaleDate(e)          { this.saleDate            = e.target.value; }
    onExpectedDelivery(e)  { this.expectedDeliveryDate = e.target.value; }
    onStatus(e)    { this.orderStatus  = e.target.value; }
    onManager(e)   { this.saleManager  = e.target.value; }

    addLineItem() {
        this.lineItemCounter++;
        this.lineItems = [...this.lineItems, {
            key: 'li_' + this.lineItemCounter, displayIndex: this.lineItemCounter,
            brand: '', packetType: '', quantity: 0, rate: 0, gstApplied: false,
            lineTotal: '0.00', stockWarning: '', stockHint: ''
        }];
    }

    removeLineItem(e) {
        const idx = parseInt(e.target.dataset.index);
        const items = [...this.lineItems];
        items.splice(idx, 1);
        items.forEach((it, i) => { it.displayIndex = i + 1; });
        this.lineItems = items;
    }

    onLineItem(e) {
        const idx   = parseInt(e.target.dataset.index);
        const field = e.target.dataset.field;
        const items = [...this.lineItems];
        const item  = { ...items[idx] };

        if      (field === 'brand')      item.brand      = e.target.value;
        else if (field === 'packetType') item.packetType = e.target.value;
        else if (field === 'quantity')   item.quantity   = parseFloat(e.target.value) || 0;
        else if (field === 'rate')       item.rate       = parseFloat(e.target.value) || 0;
        else if (field === 'gst')        item.gstApplied = e.target.checked;

        if (item.brand && item.packetType) {
            const inv      = this.inventory.find(i => i.Brand__c === item.brand && i.Packet_Type__c === item.packetType);
            const remaining = inv ? (inv.Remaining_Quantity__c || 0) : 0;
            const blocked   = inv ? (inv.blocked   || 0) : 0;
            const avail     = inv ? (inv.available  || 0) : 0;
            item.stockHint    = avail;
            item.blockedQty   = blocked;
            item.hasBlocked   = blocked > 0;
            item.blockedMsg   = blocked > 0
                ? blocked + ' KG blocked (active orders). Only ' + avail + ' KG available — confirm order for max ' + avail + ' KG.'
                : '';
            item.stockWarning = item.quantity > avail ? 'Only ' + avail + ' KG available!' : '';
        }
        const base = item.quantity * item.rate;
        item.lineTotal = (base + (item.gstApplied ? base * 0.05 : 0)).toFixed(2);
        items[idx] = item;
        this.lineItems = items;
    }

    handleSave() {
        this.saleError = '';
        if (!this.saleDate)            { this.saleError = 'Select a sale date.'; return; }
        if (!this.lineItems.length)    { this.saleError = 'Add at least one product.'; return; }
        for (let i = 0; i < this.lineItems.length; i++) {
            const li = this.lineItems[i];
            if (!li.brand)          { this.saleError = 'Item #' + (i+1) + ': Select brand.'; return; }
            if (!li.packetType)     { this.saleError = 'Item #' + (i+1) + ': Select type.'; return; }
            if (!li.quantity || li.quantity <= 0) { this.saleError = 'Item #' + (i+1) + ': Enter qty.'; return; }
            if (!li.rate     || li.rate     <= 0) { this.saleError = 'Item #' + (i+1) + ': Enter rate.'; return; }
            if (li.stockWarning) { this.saleError = 'Item #' + (i+1) + ': ' + li.stockWarning; return; }
        }

        this.isSaving = true;
        saveSale({
            sale: {
                Client__c: this.recordId, Sale_Date__c: this.saleDate,
                Order_Status__c: this.orderStatus,
                Regional_Manager__c: this.saleManager || null,
                Expected_Delivery_Date__c: this.expectedDeliveryDate || null
            },
            lineItems: this.lineItems.map(li => ({
                Brand__c: li.brand, Packet_Type__c: li.packetType,
                Quantity__c: li.quantity, Rate_Per_Kg__c: li.rate, GST_Applied__c: li.gstApplied
            }))
        })
        .then(() => {
            this.isSaving = false;
            this.closeSaleModal();
            return refreshApex(this.wiredSalesResult);
        })
        .then(() => {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Sale Saved', message: this.lineItems.length + ' item(s) recorded.', variant: 'success'
            }));
        })
        .catch(err => {
            this.isSaving = false;
            this.saleError = err.body?.message || 'Save failed.';
        });
    }

    _scrollToTop() {
        setTimeout(() => { try { window.scrollTo({ top: 0, behavior: 'smooth' }); } catch(e) {} }, 50);
    }
}
