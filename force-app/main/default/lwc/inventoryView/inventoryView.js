import { LightningElement, wire, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import getInventory from '@salesforce/apex/InventoryViewController.getInventory';
import getBrandDetail from '@salesforce/apex/InventoryViewController.getBrandDetail';
import updateShrinkage from '@salesforce/apex/InventoryViewController.updateShrinkage';

const LOW_STOCK_THRESHOLD  = 10;  // KG
const WARN_STOCK_THRESHOLD = 25;  // KG

export default class InventoryView extends LightningElement {

    @track inventory    = [];
    @track outOfStock   = [];
    @track isLoading    = true;
    wiredResult;

    @wire(getInventory)
    wiredInventory(result) {
        this.wiredResult = result;
        if (result.data) {
            this.isLoading = false;
            this.processInventory(result.data);
        } else if (result.error) {
            this.isLoading = false;
        }
    }

    processInventory(raw) {
        const inStock    = [];
        const outOfStock = [];

        raw.forEach(inv => {
            const remaining = parseFloat(inv.Remaining_Quantity__c) || 0;
            const total     = parseFloat(inv.Total_Quantity__c)     || 0;
            const avgCost   = parseFloat(inv.Avg_Cost_Per_Kg__c)    || 0;
            const sold      = parseFloat(inv.Quantity_Sold__c)      || 0;
            const value     = remaining * avgCost;
            const pct       = total > 0
                ? Math.min(100, (remaining / total) * 100) : 0;

            // Stock level classification
            let stockLabel, stockBadgeClass, cardClass, barClass;
            if (remaining <= 0) {
                outOfStock.push(this.processRow(
                    inv, remaining, total,
                    avgCost, value, pct
                ));
                return;
            } else if (remaining <= LOW_STOCK_THRESHOLD) {
                stockLabel     = '🔴 Low Stock';
                stockBadgeClass = 'stock-badge badge-low';
                cardClass      = 'inv-card card-low';
                barClass       = 'stock-bar bar-low';
            } else if (remaining <= WARN_STOCK_THRESHOLD) {
                stockLabel     = '🟡 Getting Low';
                stockBadgeClass = 'stock-badge badge-warn';
                cardClass      = 'inv-card card-warn';
                barClass       = 'stock-bar bar-warn';
            } else {
                stockLabel     = '🟢 In Stock';
                stockBadgeClass = 'stock-badge badge-ok';
                cardClass      = 'inv-card card-ok';
                barClass       = 'stock-bar bar-ok';
            }

            inStock.push({
                ...this.processRow(inv, remaining, total,
                    avgCost, value, pct),
                stockLabel,
                stockBadgeClass,
                cardClass,
                barClass,
                barStyle: 'width:' + pct.toFixed(0) + '%'
            });
        });

        this.inventory  = inStock;
        this.outOfStock = outOfStock;
    }

    processRow(inv, remaining, total, avgCost, value, pct) {
        const lastDate = inv.Last_Purchase_Date__c
            ? new Date(inv.Last_Purchase_Date__c + 'T00:00:00')
                .toLocaleDateString('en-IN', {
                    day: '2-digit', month: 'short', year: '2-digit'
                })
            : '—';

        return {
            ...inv,
            formattedCost:     parseFloat(avgCost || 0).toFixed(2),
            formattedValue:    parseFloat(value   || 0).toFixed(0),
            formattedLastDate: lastDate
        };
    }

    // ── Summary getters ─────────────────────────────────────
    get totalBrands() { return this.inventory.length; }

    get totalKg() {
        return this.inventory.reduce(
            (s, i) => s + (parseFloat(i.Remaining_Quantity__c) || 0), 0
        ).toFixed(1);
    }

    get totalValue() {
        return this.inventory.reduce(
            (s, i) => s + (
                (parseFloat(i.Remaining_Quantity__c) || 0) *
                (parseFloat(i.Avg_Cost_Per_Kg__c)    || 0)
            ), 0
        ).toFixed(0);
    }

    get lowStockCount() {
        return this.inventory.filter(
            i => (i.Remaining_Quantity__c || 0) <= LOW_STOCK_THRESHOLD
        ).length;
    }

    get hasLowStock()     { return this.lowStockCount > 0; }
    get hasOutOfStock()   { return this.outOfStock.length > 0; }
    get outOfStockCount() { return this.outOfStock.length; }

    // ── Shrinkage Modal ────────────────────────────────────
    @track isShrinkOpen   = false;
    @track isShrinkSaving = false;
    @track shrinkBrand    = '';
    @track shrinkType     = '';
    @track shrinkId       = '';
    @track shrinkValue    = '';
    @track shrinkError    = '';

    get shrinkSaveLabel() {
        return this.isShrinkSaving ? 'Saving...' : '✓ Update';
    }

    openShrink(e) {
        this.shrinkId    = e.target.dataset.id;
        this.shrinkBrand = e.target.dataset.brand;
        this.shrinkType  = e.target.dataset.type;
        this.shrinkValue = e.target.dataset.shrink || '0';
        this.shrinkError = '';
        this.isShrinkOpen = true;
    }

    closeShrink()     { this.isShrinkOpen = false; }
    onShrinkVal(e)    { this.shrinkValue  = e.target.value; }

    saveShrinkage() {
        this.shrinkError = '';
        const val = parseFloat(this.shrinkValue);
        if (isNaN(val) || val < 0) {
            this.shrinkError = 'Enter a valid positive number.';
            return;
        }
        this.isShrinkSaving = true;

        updateShrinkage({
            inventoryId: this.shrinkId,
            shrinkage:   val
        })
        .then(() => {
            this.isShrinkSaving = false;
            this.isShrinkOpen   = false;
            return refreshApex(this.wiredResult);
        })
        .then(() => {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Shrinkage updated',
                message: this.shrinkBrand + ' shrinkage set to ' +
                         val + ' KG.',
                variant: 'success'
            }));
        })
        .catch(err => {
            this.isShrinkSaving = false;
            this.shrinkError = err.body?.message || 'Update failed.';
        });
    }

    // ── Brand Detail Modal ─────────────────────────────────
    @track isDetailOpen    = false;
    @track isDetailLoading = false;
    @track detailBrand     = '';
    @track detailType      = '';
    @track detailTab       = 'purchases';
    @track detailPurchases = [];
    @track detailSales     = [];

    get purchaseTabClass() {
        return this.detailTab === 'purchases'
            ? 'detail-tab-btn detail-tab-active'
            : 'detail-tab-btn';
    }
    get salesTabClass() {
        return this.detailTab === 'sales'
            ? 'detail-tab-btn detail-tab-active'
            : 'detail-tab-btn';
    }
    get showingPurchases() { return this.detailTab === 'purchases'; }
    get showingSales()     { return this.detailTab === 'sales'; }
    get noPurchases() { return this.detailPurchases.length === 0; }
    get noSales()     { return this.detailSales.length === 0; }

    showPurchaseTab() { this.detailTab = 'purchases'; }
    showSalesTab()    { this.detailTab = 'sales'; }

    openDetail(e) {
        this.detailBrand     = e.target.dataset.brand;
        this.detailType      = e.target.dataset.type;
        this.detailTab       = 'purchases';
        this.isDetailOpen    = true;
        this.isDetailLoading = true;
        this.detailPurchases = [];
        this.detailSales     = [];

        getBrandDetail({
            brand:      this.detailBrand,
            packetType: this.detailType
        })
        .then(data => {
            this.isDetailLoading = false;

            this.detailPurchases = (data.purchases || []).map(p => ({
                ...p,
                formattedDate: p.Purchase__r.Order_Date__c
                    ? new Date(p.Purchase__r.Order_Date__c + 'T00:00:00')
                        .toLocaleDateString('en-IN', {
                            day: '2-digit', month: 'short',
                            year: '2-digit'
                        })
                    : '—',
                formattedTotal: (p.Line_Total__c || 0).toFixed(2),
                deliveryClass: this.getDeliveryClass(
                    p.Purchase__r.Delivery_Status__c
                )
            }));

            this.detailSales = (data.sales || []).map(s => ({
                ...s,
                formattedDate: s.Sale__r.Sale_Date__c
                    ? new Date(s.Sale__r.Sale_Date__c + 'T00:00:00')
                        .toLocaleDateString('en-IN', {
                            day: '2-digit', month: 'short',
                            year: '2-digit'
                        })
                    : '—',
                formattedRevenue: (s.Line_Amount__c || 0).toFixed(2),
                formattedProfit:  (s.Line_Profit__c || 0).toFixed(2)
            }));
        })
        .catch(() => { this.isDetailLoading = false; });
    }

    closeDetail() { this.isDetailOpen = false; }

    getDeliveryClass(status) {
        if (status === 'Received')         return 'dc-status green';
        if (status === 'Out for Delivery') return 'dc-status blue';
        if (status === 'Cancelled')        return 'dc-status red';
        return 'dc-status amber';
    }
}