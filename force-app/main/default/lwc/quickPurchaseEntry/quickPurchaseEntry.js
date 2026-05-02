import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import getSuppliers from '@salesforce/apex/QuickPurchaseController.getSuppliers';
import getPicklistValues from '@salesforce/apex/QuickPurchaseController.getPicklistValues';
import savePurchase from '@salesforce/apex/QuickPurchaseController.savePurchase';
import updateTax from '@salesforce/apex/QuickPurchaseController.updateTax';

import NAME_FIELD from '@salesforce/schema/Account.Name';

export default class QuickPurchaseEntry extends LightningElement {
    @api recordId;

    @wire(getRecord, { recordId: '$recordId', fields: [NAME_FIELD] })
    supplierAccount;

    get supplierName() {
        return getFieldValue(this.supplierAccount.data, NAME_FIELD) || '';
    }

    get supplierId() { return this.recordId || this._supplierId; }

    // ── Modal state ────────────────────────────────────────
    // Step 1 = main purchase form, Step 2 = tax prompt
    @track currentStep    = 1;
    @track isOpen         = false;
    @track isSaving       = false;
    @track errorMessage   = '';
    @track savedPurchaseId = '';

    // Purchase form
    @track _supplierId    = '';
    @track orderDate      = new Date().toISOString().split('T')[0];
    @track deliveryStatus = 'Order Requested';
    @track notes          = '';

    // Line items
    @track lineItems       = [];
    @track lineItemCounter = 0;

    // Advance payment
    @track hasAdvance    = false;
    @track advanceAmount = '';
    @track advanceDate   = new Date().toISOString().split('T')[0];
    @track advanceMode   = 'Cash';
    @track advancePaidBy = '';
    @track advanceNotes  = '';

    // Tax step
    @track hasTax       = false;
    @track taxAmount    = '';
    @track taxError     = '';
    @track isTaxSaving  = false;

    // Picklists
    @track brandOptions      = [];
    @track packetTypeOptions = [];
    @track deliveryStatuses  = [];
    @track teamMembers       = [];
    @track paymentModes      = [];
    @track suppliers         = [];

    @wire(getSuppliers)
    wiredSuppliers({ data }) {
        if (data) this.suppliers = data;
    }

    @wire(getPicklistValues)
    wiredPicklists({ data }) {
        if (data) {
            this.brandOptions      = data.brands || [];
            this.packetTypeOptions = data.packetTypes || [];
            this.deliveryStatuses  = data.deliveryStatuses || [];
            this.teamMembers       = data.teamMembers || [];
            this.paymentModes      = data.paymentModes || [];
            if (data.deliveryStatuses && data.deliveryStatuses.length > 0) {
                this.deliveryStatus = data.deliveryStatuses[0];
            }
        }
    }

    // ── Computed ───────────────────────────────────────────
    get isStep1() { return this.currentStep === 1; }
    get isStep2() { return this.currentStep === 2; }

    get saveLabel() {
        return this.isSaving ? 'Saving...' : '✓ Save Purchase';
    }
    get taxSaveLabel() {
        return this.isTaxSaving ? 'Saving...' : '✓ Save Tax';
    }
    get hasLineItems() { return this.lineItems.length > 0; }

    get totalCost() {
        return this.lineItems.reduce(
            (s, li) => s + parseFloat(li.lineTotal || 0), 0
        ).toFixed(2);
    }
    get totalKg() {
        return this.lineItems.reduce(
            (s, li) => s + (li.quantity || 0), 0
        ).toFixed(2);
    }
    get remainingDue() {
        const total   = parseFloat(this.totalCost) || 0;
        const advance = parseFloat(this.advanceAmount) || 0;
        return Math.max(0, total - advance).toFixed(2);
    }
    get advanceToggleLabel() { return this.hasAdvance ? 'Yes' : 'No'; }
    get totalWithTax() {
        const cost = parseFloat(this.totalCost) || 0;
        const tax  = parseFloat(this.taxAmount) || 0;
        return (cost + tax).toFixed(2);
    }

    // ── Open / Close ───────────────────────────────────────
    openModal() {
        this.resetForm();
        this.isOpen      = true;
        this.currentStep = 1;
        this._scrollToTop();
    }

    closeModal() {
        this.isOpen      = false;
        this.currentStep = 1;
        this.errorMessage = '';
    }

    handleBackdrop(e) {
        if (e.target.classList.contains('modal-backdrop')) {
            this.closeModal();
        }
    }

    resetForm() {
        this._supplierId    = '';
        this.orderDate      = new Date().toISOString().split('T')[0];
        this.notes          = '';
        this.lineItems      = [];
        this.lineItemCounter = 0;
        this.hasAdvance     = false;
        this.advanceAmount  = '';
        this.advanceDate    = new Date().toISOString().split('T')[0];
        this.advanceMode    = 'Cash';
        this.advancePaidBy  = '';
        this.advanceNotes   = '';
        this.errorMessage   = '';
        this.hasTax         = false;
        this.taxAmount      = '';
        this.taxError       = '';
        if (this.deliveryStatuses.length > 0) {
            this.deliveryStatus = this.deliveryStatuses[0];
        }
    }

    // ── Header handlers ─────────────────────────────────────
    onSupplier(e)       { this._supplierId   = e.target.value; }
    onOrderDate(e)      { this.orderDate     = e.target.value; }
    onDeliveryStatus(e) { this.deliveryStatus = e.target.value; }
    onNotes(e)          { this.notes         = e.target.value; }

    // ── Line item handlers ──────────────────────────────────
    addLineItem() {
        this.lineItemCounter++;
        this.lineItems = [...this.lineItems, {
            key: 'li_' + this.lineItemCounter,
            displayIndex: this.lineItemCounter,
            brand: '', packetType: '',
            quantity: 0, cost: 0, shrinkage: 0,
            lineTotal: '0.00', packetCount: 0
        }];
    }

    removeLineItem(e) {
        const idx = parseInt(e.target.dataset.index);
        const items = [...this.lineItems];
        items.splice(idx, 1);
        items.forEach((item, i) => { item.displayIndex = i + 1; });
        this.lineItems = items;
    }

    onLineItem(e) {
        const idx   = parseInt(e.target.dataset.index);
        const field = e.target.dataset.field;
        const items = [...this.lineItems];
        const item  = { ...items[idx] };

        if (field === 'brand')           item.brand      = e.target.value;
        else if (field === 'packetType') item.packetType = e.target.value;
        else if (field === 'quantity')   item.quantity   = parseFloat(e.target.value) || 0;
        else if (field === 'cost')       item.cost       = parseFloat(e.target.value) || 0;
        else if (field === 'shrinkage')  item.shrinkage  = parseFloat(e.target.value) || 0;

        item.lineTotal   = (item.quantity * item.cost).toFixed(2);
        item.packetCount = this.calcPackets(item.packetType, item.quantity);
        items[idx]       = item;
        this.lineItems   = items;
    }

    calcPackets(packetType, qty) {
        if (!packetType || !qty) return 0;
        if (packetType === '100g') return Math.round(qty * 10);
        if (packetType === '250g') return Math.round(qty * 4);
        return 0;
    }

    // ── Advance payment handlers ────────────────────────────
    onToggleAdvance(e) { this.hasAdvance    = e.target.checked; }
    onAdvanceAmount(e) { this.advanceAmount = e.target.value; }
    onAdvanceDate(e)   { this.advanceDate   = e.target.value; }
    onAdvanceMode(e)   { this.advanceMode   = e.target.value; }
    onAdvancePaidBy(e) { this.advancePaidBy = e.target.value; }
    onAdvanceNotes(e)  { this.advanceNotes  = e.target.value; }

    // ── Tax handlers ────────────────────────────────────────
    onToggleTax(e) { this.hasTax    = e.target.checked; }
    onTaxAmount(e) { this.taxAmount = e.target.value; }

    skipTax() {
        this.isOpen = false;
        this.dispatchEvent(new ShowToastEvent({
            title:   'Purchase Order Created',
            message: this.lineItems.length + ' product(s) ordered.',
            variant: 'success'
        }));
        // Tell parent (supplierView) to refresh its purchase list
        this.dispatchEvent(new CustomEvent('purchasecreated'));
    }

    saveTax() {
        this.taxError = '';
        if (!this.taxAmount || parseFloat(this.taxAmount) <= 0) {
            this.taxError = 'Enter a valid tax amount.'; return;
        }
        this.isTaxSaving = true;

        updateTax({
            purchaseId: this.savedPurchaseId,
            taxAmount:  parseFloat(this.taxAmount)
        })
        .then(() => {
            this.isTaxSaving = false;
            this.isOpen      = false;
            this.dispatchEvent(new ShowToastEvent({
                title:   'Purchase Saved',
                message: 'Order saved with tax of ₹' + this.taxAmount + '.',
                variant: 'success'
            }));
            // Tell parent (supplierView) to refresh its purchase list
            this.dispatchEvent(new CustomEvent('purchasecreated'));
        })
        .catch(err => {
            this.isTaxSaving = false;
            this.taxError = err.body?.message || 'Failed to save tax.';
        });
    }

    // ── Save purchase (Step 1) ──────────────────────────────
    handleSave() {
        this.errorMessage = '';
        const finalSupplierId = this.supplierId;

        if (!finalSupplierId) {
            this.errorMessage = 'Please select a supplier.'; return;
        }
        if (!this.orderDate) {
            this.errorMessage = 'Please select an order date.'; return;
        }
        if (this.lineItems.length === 0) {
            this.errorMessage = 'Please add at least one product.'; return;
        }
        for (let i = 0; i < this.lineItems.length; i++) {
            const li = this.lineItems[i];
            if (!li.brand) {
                this.errorMessage = 'Item #' + (i+1) + ': Select a brand.'; return;
            }
            if (!li.packetType) {
                this.errorMessage = 'Item #' + (i+1) + ': Select packet type.'; return;
            }
            if (!li.quantity || li.quantity <= 0) {
                this.errorMessage = 'Item #' + (i+1) + ': Enter quantity.'; return;
            }
            if (!li.cost || li.cost <= 0) {
                this.errorMessage = 'Item #' + (i+1) + ': Enter cost per KG.'; return;
            }
        }
        if (this.hasAdvance) {
            if (!this.advanceAmount || parseFloat(this.advanceAmount) <= 0) {
                this.errorMessage = 'Enter a valid advance amount.'; return;
            }
            if (parseFloat(this.advanceAmount) > parseFloat(this.totalCost)) {
                this.errorMessage = 'Advance cannot exceed ₹' + this.totalCost + '.'; return;
            }
            if (!this.advancePaidBy) {
                this.errorMessage = 'Select who made the advance payment.'; return;
            }
        }

        const purchase = {
            Supplier__c:        finalSupplierId,
            Order_Date__c:      this.orderDate,
            Delivery_Status__c: this.deliveryStatus,
            Notes__c:           this.notes || null
        };

        const lineItemsToSave = this.lineItems.map(li => ({
            Brand__c:               li.brand,
            Packet_Type__c:         li.packetType,
            Quantity__c:            li.quantity,
            Landing_Cost_Per_Kg__c: li.cost,
            Shrinkage__c:           li.shrinkage || 0
        }));

        this.isSaving = true;

        savePurchase({
            purchase,
            lineItems:         lineItemsToSave,
            hasAdvancePayment: this.hasAdvance,
            advanceAmount:     this.hasAdvance ? parseFloat(this.advanceAmount) : 0,
            advanceDate:       this.advanceDate,
            advanceMode:       this.advanceMode,
            advancePaidBy:     this.advancePaidBy,
            advanceNotes:      this.advanceNotes || ''
        })
        .then(purchaseId => {
            this.isSaving        = false;
            this.savedPurchaseId = purchaseId;
            this.hasTax          = false;
            this.taxAmount       = '';
            this.taxError        = '';
            // Move to tax step
            this.currentStep     = 2;
            this._scrollToTop();
        })
        .catch(error => {
            this.isSaving     = false;
            this.errorMessage = error.body?.message || 'An error occurred.';
        });
    }

    _scrollToTop() {
        setTimeout(() => {
            try { window.scrollTo({ top: 0, behavior: 'smooth' }); }
            catch(e) { /* silent */ }
        }, 50);
    }
}