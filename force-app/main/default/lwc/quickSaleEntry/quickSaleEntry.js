import { LightningElement, api, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import NAME_FIELD from '@salesforce/schema/Account.Name';
import getInventory from '@salesforce/apex/QuickSaleController.getInventory';
import getPicklistValues from '@salesforce/apex/QuickSaleController.getPicklistValues';
import saveSale from '@salesforce/apex/QuickSaleController.saveSale';

export default class QuickSaleEntry extends NavigationMixin(
    LightningElement
) {
    @api recordId; // Auto-passed from Account record page

    // Wire account name from recordId
    @wire(getRecord, {
        recordId: '$recordId',
        fields: [NAME_FIELD]
    })
    account;

    // Getter for client name
    get clientName() {
        return getFieldValue(this.account.data, NAME_FIELD);
    }

    @track isOpen = false;
    @track isSaving = false;
    @track errorMessage = '';
    @track saleDate = new Date().toISOString().split('T')[0];
    @track orderStatus = 'Confirmed';
    @track regionalManager = '';
    @track notes = '';
    @track lineItems = [];
    @track lineItemCounter = 0;
    @track brandOptions = [];
    @track packetTypeOptions = [];
    @track statusOptions = [];
    @track managerOptions = [];
    @track inventory = [];


    // Wire inventory
    @wire(getInventory)
    wiredInventory({ error, data }) {
        if (data) {
            this.inventory = data.map(inv => ({
                ...inv,
                stockClass: this.getStockClass(
                    inv.Remaining_Quantity__c
                )
            }));
        }
    }

    // Wire picklists
    @wire(getPicklistValues)
    wiredPicklists({ error, data }) {
        if (data) {
            this.brandOptions = data.brands || [];
            this.packetTypeOptions = data.packetTypes || [];
            this.statusOptions = data.statuses || [];
            this.managerOptions = data.managers || [];
        }
    }

    // Stock class based on quantity
    getStockClass(qty) {
        if (qty <= 0) return 'stock-item stock-empty';
        if (qty < 10) return 'stock-item stock-low';
        return 'stock-item stock-ok';
    }

    // Get available stock for a brand + packet type
    getAvailableStock(brand, packetType) {
        if (!brand || !packetType) return null;
        const inv = this.inventory.find(i =>
            i.Brand__c === brand &&
            i.Packet_Type__c === packetType
        );
        return inv ? inv.Remaining_Quantity__c : 0;
    }

    // Open modal
    openModal() {
        this.isOpen = true;
        this.resetForm();
    }

    // Close modal
    closeModal() {
        this.isOpen = false;
        this.errorMessage = '';
    }

    handleBackdropClick(e) {
        if (e.target.classList.contains('modal-backdrop')) {
            this.closeModal();
        }
    }

    // Reset form
    resetForm() {
        this.saleDate = new Date().toISOString().split('T')[0];
        this.orderStatus = 'Confirmed';
        this.regionalManager = '';
        this.notes = '';
        this.lineItems = [];
        this.lineItemCounter = 0;
        this.errorMessage = '';
    }

    // Sale header handlers
    handleSaleDate(e) { this.saleDate = e.target.value; }
    handleStatus(e) { this.orderStatus = e.target.value; }
    handleManager(e) { this.regionalManager = e.target.value; }
    handleNotes(e) { this.notes = e.target.value; }

    // Add line item
    addLineItem() {
        this.lineItemCounter++;
        this.lineItems = [...this.lineItems, {
            key: 'li_' + this.lineItemCounter,
            displayIndex: this.lineItemCounter,
            brand: '',
            packetType: '',
            quantity: 0,
            rate: 0,
            gstApplied: false,
            lineTotal: '0.00',
            availableStock: null,
            stockWarning: ''
        }];
    }

    // Remove line item
    removeLineItem(e) {
        const idx = parseInt(e.target.dataset.index);
        const items = [...this.lineItems];
        items.splice(idx, 1);
        // Reindex display numbers
        items.forEach((item, i) => {
            item.displayIndex = i + 1;
        });
        this.lineItems = items;
    }

    // Handle line item field changes
    handleLineItemChange(e) {
        const idx = parseInt(e.target.dataset.index);
        const field = e.target.dataset.field;
        const items = [...this.lineItems];
        const item = { ...items[idx] };

        if (field === 'brand') {
            item.brand = e.target.value;
        } else if (field === 'packetType') {
            item.packetType = e.target.value;
        } else if (field === 'quantity') {
            item.quantity = parseFloat(e.target.value) || 0;
        } else if (field === 'rate') {
            item.rate = parseFloat(e.target.value) || 0;
        } else if (field === 'gst') {
            item.gstApplied = e.target.checked;
        }

        // Get available stock
        if (item.brand && item.packetType) {
            const avail = this.getAvailableStock(
                item.brand, item.packetType
            );
            item.availableStock = avail;

            // Show warning if quantity exceeds stock
            if (item.quantity > avail) {
                item.stockWarning =
                    'Only ' + avail + ' KG available!';
            } else {
                item.stockWarning = '';
            }
        }

        // Recalculate line total
        const baseAmt = item.quantity * item.rate;
        const gstAmt = item.gstApplied ? baseAmt * 0.05 : 0;
        item.lineTotal = (baseAmt + gstAmt).toFixed(2);

        items[idx] = item;
        this.lineItems = items;
    }

    // Computed totals
    get totalRevenue() {
        const total = this.lineItems.reduce((sum, li) => {
            return sum + (li.quantity * li.rate);
        }, 0);
        return total.toFixed(2);
    }

    get totalGST() {
        const total = this.lineItems.reduce((sum, li) => {
            if (li.gstApplied) {
                return sum + (li.quantity * li.rate * 0.05);
            }
            return sum;
        }, 0);
        return total > 0 ? total.toFixed(2) : null;
    }

    get grandTotal() {
        const total = this.lineItems.reduce((sum, li) => {
            return sum + parseFloat(li.lineTotal || 0);
        }, 0);
        return total.toFixed(2);
    }

    get hasLineItems() {
        return this.lineItems.length > 0;
    }

    // Validate and save
    handleSave() {
        this.errorMessage = '';

        // Validation
        if (!this.saleDate) {
            this.errorMessage = 'Please select a Sale Date.';
            return;
        }
        if (this.lineItems.length === 0) {
            this.errorMessage =
                'Please add at least one line item.';
            return;
        }
        for (let i = 0; i < this.lineItems.length; i++) {
            const li = this.lineItems[i];
            if (!li.brand) {
                this.errorMessage =
                    'Line item #' + (i + 1) +
                    ': Please select a brand.';
                return;
            }
            if (!li.packetType) {
                this.errorMessage =
                    'Line item #' + (i + 1) +
                    ': Please select packet type.';
                return;
            }
            if (!li.quantity || li.quantity <= 0) {
                this.errorMessage =
                    'Line item #' + (i + 1) +
                    ': Quantity must be greater than 0.';
                return;
            }
            if (!li.rate || li.rate <= 0) {
                this.errorMessage =
                    'Line item #' + (i + 1) +
                    ': Rate must be greater than 0.';
                return;
            }
            if (li.stockWarning) {
                this.errorMessage =
                    'Line item #' + (i + 1) +
                    ': ' + li.stockWarning;
                return;
            }
        }

        // Build sale object
        const sale = {
            Client__c: this.recordId,
            Sale_Date__c: this.saleDate,
            Order_Status__c: this.orderStatus,
            Regional_Manager__c: this.regionalManager || null,
            Notes__c: this.notes || null
        };

        // Build line items
        const lineItemsToSave = this.lineItems.map(li => ({
            Brand__c: li.brand,
            Packet_Type__c: li.packetType,
            Quantity__c: li.quantity,
            Rate_Per_Kg__c: li.rate,
            GST_Applied__c: li.gstApplied
        }));

        this.isSaving = true;

        saveSale({ sale, lineItems: lineItemsToSave })
            .then(saleId => {
                this.isSaving = false;
                this.closeModal();

                // Show success toast
                this.dispatchEvent(new ShowToastEvent({
                    title: 'Sale Created Successfully',
                    message: 'Sale and ' +
                        this.lineItems.length +
                        ' line item(s) saved.',
                    variant: 'success'
                }));

                // Navigate to the new Sale record
                this[NavigationMixin.Navigate]({
                    type: 'standard__recordPage',
                    attributes: {
                        recordId: saleId,
                        actionName: 'view'
                    }
                });
            })
            .catch(error => {
                this.isSaving = false;
                this.errorMessage =
                    error.body?.message || 'An error occurred.';
            });
    }
}