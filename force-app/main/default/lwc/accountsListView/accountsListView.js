import { LightningElement, track, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';
import getAccounts from '@salesforce/apex/AccountsListController.getAccounts';

export default class AccountsListView extends NavigationMixin(
    LightningElement
) {
    @track searchTerm    = '';
    @track activeTab     = 'clients';
    @track isLoading     = true;
    @track clients       = [];
    @track suppliers     = [];
    @track _searchTimer  = null;

    wiredAccountsResult;

    @wire(getAccounts, { searchTerm: '$searchTerm' })
    wiredAccounts(result) {
        this.wiredAccountsResult = result;
        if (result.data) {
            this.isLoading = false;
            this.processData(result.data);
        } else if (result.error) {
            this.isLoading = false;
            console.error(result.error);
        }
    }

    // Fires on every navigation in Salesforce mobile app
    // More reliable than visibilitychange for SF mobile
    @wire(CurrentPageReference)
    pageRefHandler(pageRef) {
        if (pageRef && this.wiredAccountsResult) {
            refreshApex(this.wiredAccountsResult);
        }
    }

    connectedCallback() {
        // visibilitychange handles browser tab switching
        this._visHandler = () => {
            if (!document.hidden && this.wiredAccountsResult) {
                refreshApex(this.wiredAccountsResult);
            }
        };
        document.addEventListener('visibilitychange', this._visHandler);
    }

    disconnectedCallback() {
        document.removeEventListener('visibilitychange', this._visHandler);
    }

    processData(data) {
        // Process clients
        const mapped = (data.clients || []).map(c => {
            const balance           = parseFloat(c.balance) || 0;
            const hasBalance        = balance > 0;
            const confirmed         = parseInt(c.confirmedCount)      || 0;
            const outForDelivery    = parseInt(c.outForDeliveryCount) || 0;

            // Format upcoming delivery date
            let deliveryDateLabel = null;
            let deliveryIsToday   = false;
            let deliveryIsTomorrow = false;
            let deliveryIsDelayed = false;
            if (c.delayedDeliveryDate) {
                // Overdue takes priority over any upcoming date
                const d     = new Date(c.delayedDeliveryDate + 'T00:00:00');
                const today = new Date(); today.setHours(0,0,0,0);
                const daysLate = Math.round((today - d) / (1000 * 60 * 60 * 24));
                deliveryIsDelayed = true;
                deliveryDateLabel = 'Delivery Delayed' +
                    (daysLate > 0 ? ' · ' + daysLate + 'd' : '');
            } else if (c.upcomingDeliveryDate) {
                const d     = new Date(c.upcomingDeliveryDate + 'T00:00:00');
                const today = new Date(); today.setHours(0,0,0,0);
                const diff  = Math.round((d - today) / (1000 * 60 * 60 * 24));
                deliveryIsToday    = diff === 0;
                deliveryIsTomorrow = diff === 1;
                deliveryDateLabel  = deliveryIsToday  ? 'Deliver Today!'
                                   : deliveryIsTomorrow ? 'Deliver Tomorrow'
                                   : d.toLocaleDateString('en-IN',
                                       { day:'2-digit', month:'short' });
            }
            const hasConfirmed      = confirmed > 0;
            const hasOutForDelivery = outForDelivery > 0;
            const hasActiveOrders   = hasConfirmed || hasOutForDelivery;

            // Show "Clear" ONLY when no active orders AND no balance due
            const showClear = !hasActiveOrders && !hasBalance;

            // Card border colour priority:
            // red = delayed, amber = out for delivery, blue = confirmed, orange = due, green = clear
            let cardClass = 'client-card card-clear';
            if (deliveryIsDelayed)     cardClass = 'client-card card-delayed';
            else if (hasOutForDelivery) cardClass = 'client-card card-transit';
            else if (hasConfirmed)     cardClass = 'client-card card-confirmed';
            else if (hasBalance)       cardClass = 'client-card card-has-balance';

            // Sort weight: lower = higher in list. Delayed deliveries are
            // the most urgent state — always float to the very top.
            // Confirmed orders (even with ₹0 balance, since balance only
            // counts delivered sales) rank above plain balance-due clients.
            let sortWeight = 5; // clear
            if (deliveryIsDelayed)                    sortWeight = -1;
            else if (hasOutForDelivery && hasBalance) sortWeight = 0;
            else if (hasOutForDelivery)               sortWeight = 1;
            else if (hasConfirmed && hasBalance)      sortWeight = 2;
            else if (hasConfirmed)                    sortWeight = 3;
            else if (hasBalance)                      sortWeight = 4;

            return {
                ...c,
                hasBalance,
                formattedBalance:    balance.toFixed(2),
                hasConfirmed,
                hasOutForDelivery,
                hasActiveOrders,
                showClear,
                deliveryDateLabel,
                deliveryIsToday,
                deliveryIsTomorrow,
                deliveryIsDelayed,
                deliveryDateClass: deliveryIsDelayed  ? 'delivery-badge delayed'
                                 : deliveryIsToday    ? 'delivery-badge urgent'
                                 : deliveryIsTomorrow ? 'delivery-badge soon'
                                 : deliveryDateLabel  ? 'delivery-badge normal'
                                 : '',
                confirmedCount:      confirmed,
                outForDeliveryCount: outForDelivery,
                cardClass,
                sortWeight,
                sortBalance: balance
            };
        });

        // Sort: Out for Delivery+Due → Out for Delivery → Confirmed+Due → Due → Confirmed → Clear
        this.clients = mapped.sort((a, b) => {
            if (a.sortWeight !== b.sortWeight) return a.sortWeight - b.sortWeight;
            return b.sortBalance - a.sortBalance; // higher balance first within same group
        });

        // Process suppliers
        this.suppliers = (data.suppliers || []).map(s => {
            const outstanding = parseFloat(s.outstanding) || 0;
            return {
                ...s,
                hasOutstanding: outstanding > 0,
                formattedOutstanding: outstanding.toFixed(2),
                initial: s.name ? s.name.charAt(0).toUpperCase() : '?'
            };
        });
    }

    // ── Computed ──────────────────────────────────────────
    get clientCount()     { return this.clients.length; }
    get supplierCount()   { return this.suppliers.length; }
    get showingClients()  { return this.activeTab === 'clients'; }
    get showingSuppliers(){ return this.activeTab === 'suppliers'; }
    get noClients()       { return this.clients.length === 0; }
    get noSuppliers()     { return this.suppliers.length === 0; }

    get clientTabClass() {
        return this.activeTab === 'clients'
            ? 'tab-btn tab-active tab-client'
            : 'tab-btn';
    }
    get supplierTabClass() {
        return this.activeTab === 'suppliers'
            ? 'tab-btn tab-active tab-supplier'
            : 'tab-btn';
    }

    get totalOutstanding() {
        return this.clients.reduce(
            (s, c) => s + (parseFloat(c.balance) || 0), 0
        ).toFixed(2);
    }
    get hasOutstanding() {
        return this.clients.some(c => c.hasBalance);
    }
    get clientsWithBalance() {
        return this.clients.filter(c => c.hasBalance).length;
    }

    // ── Handlers ──────────────────────────────────────────
    showClients()  { this.activeTab = 'clients'; }
    showSuppliers(){ this.activeTab = 'suppliers'; }

    onSearch(e) {
        const val = e.target.value;
        // Debounce 300ms
        clearTimeout(this._searchTimer);
        this._searchTimer = setTimeout(() => {
            this.searchTerm = val;
            this.isLoading  = true;
        }, 300);
    }

    clearSearch() {
        this.searchTerm = '';
        this.isLoading  = true;
        // Clear input
        const input = this.template.querySelector('.search-input');
        if (input) input.value = '';
    }

    openAccount(e) {
        const accountId = e.currentTarget.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId:   accountId,
                actionName: 'view'
            }
        });
    }
}