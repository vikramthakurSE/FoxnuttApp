import { LightningElement, track, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getPendingOrders from '@salesforce/apex/PendingWebOrdersController.getPendingOrders';
import approveOrder from '@salesforce/apex/PendingWebOrdersController.approveOrder';
import rejectOrder from '@salesforce/apex/PendingWebOrdersController.rejectOrder';

export default class PendingWebOrders extends LightningElement {
    @track orders = [];
    loading = true;
    busy = false;
    error;

    wiredResult;

    @wire(getPendingOrders)
    wiredOrders(result) {
        this.wiredResult = result;
        this.loading = false;
        if (result.data) {
            this.orders = result.data;
            this.error = undefined;
        } else if (result.error) {
            this.error = result.error?.body?.message || 'Could not load orders.';
            this.orders = [];
        }
    }

    get isEmpty() {
        return !this.loading && !this.error && this.orders.length === 0;
    }

    handleRefresh() {
        this.loading = true;
        refreshApex(this.wiredResult).finally(() => {
            this.loading = false;
        });
    }

    handleApprove(event) {
        this.act(
            approveOrder,
            event.target.dataset.id,
            'Order approved — stock is blocked and the customer has been messaged.'
        );
    }

    handleReject(event) {
        this.act(rejectOrder, event.target.dataset.id, 'Order cancelled.');
    }

    act(apexMethod, saleId, successMessage) {
        if (!saleId || this.busy) return;
        this.busy = true;
        apexMethod({ saleId })
            .then(() => {
                this.toast('Success', successMessage, 'success');
                return refreshApex(this.wiredResult);
            })
            .catch((e) => {
                this.toast(
                    'Could not update the order',
                    e?.body?.message || 'Something went wrong.',
                    'error'
                );
            })
            .finally(() => {
                this.busy = false;
            });
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
