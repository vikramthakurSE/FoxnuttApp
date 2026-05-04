import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import getSupplierData from '@salesforce/apex/SupplierViewController.getSupplierData';
import saveMfrPayment from '@salesforce/apex/SupplierViewController.saveMfrPayment';
import updateDeliveryStatus from '@salesforce/apex/SupplierViewController.updateDeliveryStatus';

import NAME_FIELD  from '@salesforce/schema/Account.Name';
import PHONE_FIELD from '@salesforce/schema/Account.Phone';

const FIELDS = [NAME_FIELD, PHONE_FIELD];

export default class SupplierView extends NavigationMixin(LightningElement) {
    @api recordId;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    accountRecord;

    get supplierName() {
        return getFieldValue(this.accountRecord.data, NAME_FIELD) || '';
    }
    get phone() {
        return getFieldValue(this.accountRecord.data, PHONE_FIELD);
    }

    // ── Purchases ──────────────────────────────────────────
    @track purchases = [];
    @track isLoading = true;
    wiredResult;

    @wire(getSupplierData, { supplierId: '$recordId' })
    wiredPurchases(result) {
        this.wiredResult = result;
        if (result.data) {
            this.isLoading = false;
            this.purchases = this.processPurchases(result.data);
        } else if (result.error) {
            this.isLoading = false;
        }
    }

    connectedCallback() {
        this._visHandler = () => {
            if (!document.hidden && this.wiredResult) {
                refreshApex(this.wiredResult);
            }
        };
        document.addEventListener('visibilitychange', this._visHandler);
    }

    disconnectedCallback() {
        document.removeEventListener('visibilitychange', this._visHandler);
    }

    // Called when quickPurchaseEntry fires purchasecreated event
    handlePurchaseCreated() {
        refreshApex(this.wiredResult);
    }

    processPurchases(raw) {
        return raw.map(p => {
            const total       = parseFloat(p.Total_Order_Cost__c) || 0;
            const tax         = parseFloat(p.Tax_Amount__c)        || 0;
            const paid        = parseFloat(p.Total_Paid__c)        || 0;
            // Total due = order cost + tax - what's already paid
            const totalDue    = total + tax;
            const outstanding = Math.max(0, totalDue - paid);

            // Payment status class
            const ps = p.Manufacturer_Payment_Status__c || '';
            let payStatusClass = 'pay-badge ';
            if (ps === 'Fully Paid' || ps === 'Paid')
                payStatusClass += 'badge-paid';
            else if (ps === 'Partially Paid')
                payStatusClass += 'badge-partial';
            else
                payStatusClass += 'badge-unpaid';

            // Delivery status class
            const ds = p.Delivery_Status__c || '';
            let deliveryClass = 'delivery-badge ';
            if (ds === 'Received')
                deliveryClass += 'dbadge-received';
            else if (ds === 'Out for Delivery')
                deliveryClass += 'dbadge-transit';
            else if (ds === 'Cancelled')
                deliveryClass += 'dbadge-cancelled';
            else
                deliveryClass += 'dbadge-pending';

            const outstandingClass = outstanding > 0
                ? 'fin-val red' : 'fin-val green';

            // Delivery status flow (one-way, locks at Received/Cancelled)
            const deliveryOrder = [
                'Order Requested', 'Confirmed',
                'Out for Delivery', 'Received'
            ];
            const curDIdx  = deliveryOrder.indexOf(ds);
            const dsLocked = ds === 'Received' || ds === 'Cancelled';

            const dsBtnClass = (btnStatus) => {
                const btnIdx    = deliveryOrder.indexOf(btnStatus);
                const isCurrent = btnStatus === ds;
                const isPast    = btnIdx < curDIdx;
                const isDisabled = dsLocked || isPast || isCurrent;
                let cls = 'ds-btn ';
                if (btnStatus === 'Order Requested') cls += 'ds-requested';
                else if (btnStatus === 'Confirmed')  cls += 'ds-confirmed';
                else if (btnStatus === 'Out for Delivery') cls += 'ds-transit';
                else if (btnStatus === 'Received')   cls += 'ds-received';
                if (isCurrent)  cls += ' ds-active';
                if (isDisabled) cls += ' ds-disabled';
                return cls;
            };

            const lineItems = (p.Purchase_Line_Items__r || []).map(li => ({
                ...li,
                formattedTotal: (
                    (li.Quantity__c || 0) *
                    (li.Landing_Cost_Per_Kg__c || 0)
                ).toFixed(2)
            }));

            const mfrPayments = (p.Manufacturer_Payments__r || []).map(mp => ({
                ...mp,
                formattedAmount: (mp.Amount_Paid__c || 0).toFixed(2),
                formattedDate: mp.Payment_Date__c
                    ? new Date(mp.Payment_Date__c + 'T00:00:00')
                        .toLocaleDateString('en-IN', {
                            day: '2-digit', month: 'short'
                        })
                    : '—'
            }));

            const purDate = p.Order_Date__c
                ? new Date(p.Order_Date__c + 'T00:00:00')
                    .toLocaleDateString('en-IN', {
                        day: '2-digit', month: 'short', year: '2-digit'
                    })
                : '—';

            return {
                ...p,
                isExpanded: false,
                formattedDate: purDate,
                formattedTotal:       total.toFixed(2),
                formattedTax:         tax.toFixed(2),
                formattedTotalDue:    totalDue.toFixed(2),
                formattedPaid:        paid.toFixed(2),
                formattedOutstanding: outstanding.toFixed(2),
                payStatusClass,
                deliveryClass,
                outstandingClass,
                chevronClass: 'pur-chevron',
                lineItems,
                hasLineItems:  lineItems.length > 0,
                mfrPayments,
                hasPayments:   mfrPayments.length > 0,
                hasOutstanding: outstanding > 0,
                hasTax:        tax > 0,
                dsLocked,
                btnClassRequested: dsBtnClass('Order Requested'),
                btnClassConfirmed: dsBtnClass('Confirmed'),
                btnClassTransit:   dsBtnClass('Out for Delivery'),
                btnClassReceived:  dsBtnClass('Received'),
            };
        });
    }

    // ── Summary getters ─────────────────────────────────────
    get totalPurchasesCount() { return this.purchases.length; }
    get isEmpty() {
        return !this.isLoading && this.purchases.length === 0;
    }

    get totalOrdered() {
        return this.purchases.reduce(
            (s, p) => s + (parseFloat(p.Total_Order_Cost__c) || 0), 0
        ).toFixed(2);
    }
    get totalPaid() {
        return this.purchases.reduce(
            (s, p) => s + (parseFloat(p.Total_Paid__c) || 0), 0
        ).toFixed(2);
    }
    get totalOutstanding() {
        // Include tax in total outstanding
        return this.purchases.reduce((s, p) => {
            const total = parseFloat(p.Total_Order_Cost__c) || 0;
            const tax   = parseFloat(p.Tax_Amount__c)       || 0;
            const paid  = parseFloat(p.Total_Paid__c)       || 0;
            return s + Math.max(0, total + tax - paid);
        }, 0).toFixed(2);
    }
    get hasOutstanding() {
        return this.purchases.some(p => {
            const total = parseFloat(p.Total_Order_Cost__c) || 0;
            const tax   = parseFloat(p.Tax_Amount__c)       || 0;
            const paid  = parseFloat(p.Total_Paid__c)       || 0;
            return (total + tax - paid) > 0;
        });
    }
    get brandList() {
        const brands = new Set();
        this.purchases.forEach(p => {
            (p.Purchase_Line_Items__r || []).forEach(li => {
                if (li.Brand__c) brands.add(li.Brand__c);
            });
        });
        return [...brands].join(' · ') || '';
    }

    togglePurchase(e) {
        const purId = e.currentTarget.dataset.id;
        this.purchases = this.purchases.map(p => {
            if (p.Id === purId) {
                const expanded = !p.isExpanded;
                return {
                    ...p,
                    isExpanded: expanded,
                    chevronClass: expanded
                        ? 'pur-chevron rotated'
                        : 'pur-chevron'
                };
            }
            return p;
        });
    }

    viewPurchase(e) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: e.target.dataset.id,
                actionName: 'view'
            }
        });
    }

    updateDeliveryStatus(e) {
        const purId     = e.currentTarget.dataset.id;
        const newStatus = e.currentTarget.dataset.status;
        const pur       = this.purchases.find(p => p.Id === purId);
        if (!pur) return;
        if (pur.Delivery_Status__c === newStatus) return;

        if (pur.dsLocked) {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Status Locked',
                message: 'A ' + pur.Delivery_Status__c + ' order cannot be changed.',
                variant: 'warning'
            }));
            return;
        }

        const order = ['Order Requested','Confirmed','Out for Delivery','Received'];
        const curIdx = order.indexOf(pur.Delivery_Status__c);
        const newIdx = order.indexOf(newStatus);
        if (newIdx <= curIdx) {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Cannot Go Back',
                message: 'Status can only move forward.',
                variant: 'warning'
            }));
            return;
        }

        // Optimistic update
        this.purchases = this.purchases.map(p => {
            if (p.Id !== purId) return p;
            let deliveryClass = 'delivery-badge ';
            if (newStatus === 'Received')          deliveryClass += 'dbadge-received';
            else if (newStatus === 'Out for Delivery') deliveryClass += 'dbadge-transit';
            else if (newStatus === 'Confirmed')    deliveryClass += 'dbadge-pending';
            else                                   deliveryClass += 'dbadge-pending';
            return { ...p, Delivery_Status__c: newStatus, deliveryClass, dsLocked: newStatus === 'Received' };
        });

        updateDeliveryStatus({ purchaseId: purId, status: newStatus })
            .then(() => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Status Updated',
                    message: 'Purchase is now ' + newStatus + '.',
                    variant: 'success'
                }));
                return refreshApex(this.wiredResult);
            })
            .catch(err => {
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Failed', message: err.body?.message || 'Error.', variant: 'error'
                }));
                refreshApex(this.wiredResult);
            });
    }

    newPurchase() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Purchase__c',
                actionName: 'new'
            },
            state: {
                defaultFieldValues: 'Supplier__c=' + this.recordId
            }
        });
    }

    // ── Pay Manufacturer modal ──────────────────────────────
    @track isPaymentOpen     = false;
    @track isPaySaving       = false;
    @track paymentPurchaseId = '';
    @track paymentPurchaseName = '';
    @track paymentBalance    = '';
    @track paymentAmount     = '';
    @track paymentDate       = new Date().toISOString().split('T')[0];
    @track paymentMode       = 'Cash';
    @track paymentBy         = '';
    @track paymentRef        = '';
    @track paymentError      = '';

    get paymentModes() { return ['Cash', 'UPI', 'Cheque', 'NEFT/RTGS']; }
    get teamMembers()  { return ['Vikram', 'Rohan', 'Aryan', 'Self']; }
    get paySaveLabel() {
        return this.isPaySaving ? 'Saving...' : '✓ Record Payment';
    }

    openPaymentModal(e) {
        this.paymentPurchaseId   = e.target.dataset.id;
        this.paymentPurchaseName = e.target.dataset.name;
        const bal = parseFloat(e.target.dataset.outstanding || 0);
        this.paymentBalance = bal.toFixed(2);
        this.paymentAmount  = this.paymentBalance;
        this.paymentDate    = new Date().toISOString().split('T')[0];
        this.paymentMode    = 'Cash';
        this.paymentBy      = '';
        this.paymentRef     = '';
        this.paymentError   = '';
        this.isPaymentOpen  = true;
        this._scrollToTop();
    }

    closePaymentModal() { this.isPaymentOpen = false; }

    onPayAmt(e)  { this.paymentAmount = e.target.value; }
    onPayDate(e) { this.paymentDate   = e.target.value; }
    onPayMode(e) { this.paymentMode   = e.target.value; }
    onPayBy(e)   { this.paymentBy     = e.target.value; }
    onPayRef(e)  { this.paymentRef    = e.target.value; }

    handlePaySave() {
        this.paymentError = '';
        if (!this.paymentAmount || parseFloat(this.paymentAmount) <= 0) {
            this.paymentError = 'Enter a valid amount.'; return;
        }
        if (!this.paymentDate) {
            this.paymentError = 'Select payment date.'; return;
        }
        if (!this.paymentBy) {
            this.paymentError = 'Select who paid.'; return;
        }

        this.isPaySaving = true;

        saveMfrPayment({
            purchaseId:  this.paymentPurchaseId,
            amount:      parseFloat(this.paymentAmount),
            paymentDate: this.paymentDate,
            mode:        this.paymentMode,
            paidBy:      this.paymentBy,
            notes:       this.paymentRef || ''
        })
        .then(() => {
            this.isPaySaving   = false;
            this.isPaymentOpen = false;
            return refreshApex(this.wiredResult);
        })
        .then(() => {
            this.dispatchEvent(new ShowToastEvent({
                title: 'Payment recorded',
                message: '₹' + this.paymentAmount + ' paid to supplier.',
                variant: 'success'
            }));
        })
        .catch(err => {
            this.isPaySaving  = false;
            this.paymentError = err.body?.message || 'Save failed.';
        });
    }

    _scrollToTop() {
        setTimeout(() => {
            try {
                window.scrollTo({ top: 0, behavior: 'smooth' });
            } catch(e) { /* silent */ }
        }, 50);
    }
}