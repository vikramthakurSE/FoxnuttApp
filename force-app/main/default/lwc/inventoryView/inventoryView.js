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
            // Build blocked map: brand|packetType → blocked KG
            const blockedMap = {};
            (result.data.blocked || []).forEach(b => {
                blockedMap[b.key] = parseFloat(b.blocked) || 0;
            });
            this.processInventory(result.data.inventory || [], blockedMap);
        } else if (result.error) {
            this.isLoading = false;
        }
    }

    processInventory(raw, blockedMap) {
        const inStock    = [];
        const outOfStock = [];

        raw.forEach(inv => {
            const remaining  = parseFloat(inv.Remaining_Quantity__c) || 0;
            const total      = parseFloat(inv.Total_Quantity__c)     || 0;
            const avgCost    = parseFloat(inv.Avg_Cost_Per_Kg__c)    || 0;
            const sold       = parseFloat(inv.Quantity_Sold__c)      || 0;
            const key        = (inv.Brand__c || '') + '|' + (inv.Packet_Type__c || '');
            const blocked    = blockedMap[key] || 0;
            const available  = Math.max(0, remaining - blocked);
            const value      = available * avgCost;
            const pct        = total > 0
                ? Math.min(100, (available / total) * 100) : 0;

            // Stock classification based on AVAILABLE (not just remaining)
            let stockLabel, stockBadgeClass, cardClass, barClass;
            if (available <= 0 && remaining <= 0) {
                outOfStock.push(this.processRow(
                    inv, remaining, total, avgCost, value,
                    pct, blocked, available
                ));
                return;
            } else if (available <= LOW_STOCK_THRESHOLD) {
                stockLabel      = '🔴 Low Stock';
                stockBadgeClass = 'stock-badge badge-low';
                cardClass       = 'inv-card card-low';
                barClass        = 'stock-bar bar-low';
            } else if (available <= WARN_STOCK_THRESHOLD) {
                stockLabel      = '🟡 Getting Low';
                stockBadgeClass = 'stock-badge badge-warn';
                cardClass       = 'inv-card card-warn';
                barClass        = 'stock-bar bar-warn';
            } else {
                stockLabel      = '🟢 In Stock';
                stockBadgeClass = 'stock-badge badge-ok';
                cardClass       = 'inv-card card-ok';
                barClass        = 'stock-bar bar-ok';
            }

            inStock.push({
                ...this.processRow(inv, remaining, total,
                    avgCost, value, pct, blocked, available),
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

    processRow(inv, remaining, total, avgCost, value, pct, blocked, available) {
        const lastDate = inv.Last_Purchase_Date__c
            ? new Date(inv.Last_Purchase_Date__c + 'T00:00:00')
                .toLocaleDateString('en-IN', {
                    day: '2-digit', month: 'short', year: '2-digit'
                })
            : '—';

        return {
            ...inv,
            formattedCost:      parseFloat(avgCost   || 0).toFixed(2),
            formattedValue:     parseFloat(value     || 0).toFixed(0),
            formattedLastDate:  lastDate,
            blockedQty:         blocked   || 0,
            availableQty:       available !== undefined ? available : remaining,
            hasBlocked:         (blocked  || 0) > 0
        };
    }

    // ── Summary getters ─────────────────────────────────────
    get totalBrands() { return this.inventory.length; }

    get totalKg() {
        return this.inventory.reduce(
            (s, i) => s + (parseFloat(i.availableQty) || 0), 0
        ).toFixed(1);
    }

    get totalValue() {
        return this.inventory.reduce(
            (s, i) => s + (
                (parseFloat(i.availableQty)         || 0) *
                (parseFloat(i.Avg_Cost_Per_Kg__c)   || 0)
            ), 0
        ).toFixed(0);
    }

    get lowStockCount() {
        return this.inventory.filter(
            i => (i.availableQty || 0) <= LOW_STOCK_THRESHOLD
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
        this._scrollToTop();
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
        this._scrollToTop();

        getBrandDetail({
            brand:      this.detailBrand,
            packetType: this.detailType
        })
        .then(data => {
            this.isDetailLoading = false;

            // Purchase__r / Sale__r (and their nested Supplier__r / Client__r)
            // can be null when the parent record has no supplier/client set —
            // flatten with fallbacks here so the template never dereferences
            // undefined (that was freezing the modal for some brands).
            this.detailPurchases = (data.purchases || []).map(p => ({
                ...p,
                purchaseName: p.Purchase__r?.Name || '—',
                supplierName: p.Purchase__r?.Supplier__r?.Name || 'Unknown Supplier',
                deliveryStatusLabel: p.Purchase__r?.Delivery_Status__c || '—',
                formattedDate: p.Purchase__r?.Order_Date__c
                    ? new Date(p.Purchase__r.Order_Date__c + 'T00:00:00')
                        .toLocaleDateString('en-IN', {
                            day: '2-digit', month: 'short',
                            year: '2-digit'
                        })
                    : '—',
                formattedTotal: (p.Line_Total__c || 0).toFixed(2),
                deliveryClass: this.getDeliveryClass(
                    p.Purchase__r?.Delivery_Status__c
                )
            }));

            this.detailSales = (data.sales || []).map(s => {
                const lineAmt   = s.Line_Amount__c   || 0;
                const lineProfit = s.Line_Profit__c  || 0;
                const saleCd    = s.Sale__r?.Total_CD_Amount__c || 0;
                const saleRev   = s.Sale__r?.Total_Revenue__c  || 0;

                // Apportion CD to this line item by its share of sale revenue
                const cdShare   = saleRev > 0
                    ? (lineAmt / saleRev) * saleCd : 0;
                const effectiveRevenue = Math.max(0, lineAmt - cdShare);
                const effectiveProfit  = Math.max(0, lineProfit - cdShare);

                return {
                    ...s,
                    saleName:  s.Sale__r?.Name || '—',
                    clientName: s.Sale__r?.Client__r?.Name || 'Unknown Client',
                    formattedDate: s.Sale__r?.Sale_Date__c
                        ? new Date(s.Sale__r.Sale_Date__c + 'T00:00:00')
                            .toLocaleDateString('en-IN', {
                                day: '2-digit', month: 'short',
                                year: '2-digit'
                            })
                        : '—',
                    formattedRevenue: effectiveRevenue.toFixed(2),
                    formattedProfit:  effectiveProfit.toFixed(2),
                    hasCd:     saleCd > 0,
                    cdAmount:  cdShare.toFixed(2)
                };
            });
        })
        .catch(() => { this.isDetailLoading = false; });
    }

    closeDetail() { this.isDetailOpen = false; }

    _scrollToTop() {
        try {
            window.scrollTo(0, 0);
        } catch (e) { /* silent */ }
    }

    getDeliveryClass(status) {
        if (status === 'Received')         return 'dc-status green';
        if (status === 'Out for Delivery') return 'dc-status blue';
        if (status === 'Cancelled')        return 'dc-status red';
        return 'dc-status amber';
    }
}