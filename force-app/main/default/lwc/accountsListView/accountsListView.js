import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
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

    @wire(getAccounts, { searchTerm: '$searchTerm' })
    wiredAccounts({ data, error }) {
        if (data) {
            this.isLoading = false;
            this.processData(data);
        } else if (error) {
            this.isLoading = false;
            console.error(error);
        }
    }

    processData(data) {
        // Process clients
        this.clients = (data.clients || []).map(c => {
            const balance = parseFloat(c.balance) || 0;
            const hasBalance = balance > 0;
            return {
                ...c,
                hasBalance,
                formattedBalance: balance.toFixed(2),
                cardClass: hasBalance
                    ? 'client-card card-has-balance'
                    : 'client-card card-clear'
            };
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