# FoxnuttApp
Salesforce Makhana App to track sales, inventories, revenue, etc

## Bank credit alerts → automatic Client Payments

Axis Bank emails an alert for every credit ("INR x was credited to your
A/c."). Gmail auto-forwards those to the org's email service address and
`AxisCreditAlertHandler` turns each one into a **Bank Credit Alert**
record. When the credit can be tied to a client with an open order it also
creates the `Client_Payment__c`, which fires the existing payment-received
WhatsApp and balance roll-ups. Nothing is booked on a guess: anything
ambiguous stays **Needs Review** (list view on the Bank Credit Alerts tab)
and sends a push notification.

Matching, in order: order number in the UPI remark (`SAL-0059`), business
code in the remark, a UPI payer name already learned on exactly one client
(`Account.UPI_Payer_Name__c`, filled in automatically after a client's
first matched payment), an amount that equals exactly one client's open
balance, then payer name against the account or contact person (only if it
points at a single client). Customers do not need to type anything in the
remark; Axis truncates it anyway. A payment larger than the oldest balance is
split across that client's open orders, oldest first. Duplicate UTRs are
ignored.

Service address (Setup → Email Services → AxisCreditAlerts):

```
axis-alerts@2sc2hn7fvbqe7ihvib3pt198we9t5gcre24zn3po64pnxnvbt9.dl-e2tyduaz.ind134.apex.salesforce.com
```

One-time Gmail setup (the inbox that receives the Axis alerts):

1. Settings → Forwarding and POP/IMAP → **Add a forwarding address** →
   paste the service address. Gmail sends a confirmation code *to that
   address*; it shows up in Salesforce as a Bank Credit Alert with status
   "Not a Credit" — open it and copy the code from **Raw Body**.
2. Settings → Filters → **Create a new filter**: From `alerts@axis.bank.in`,
   Subject `credited`. Action: **Forward it to** the service address.
   (Do not turn on "forward all mail".)

Authorised senders are `alerts@axis.bank.in`, Google's forwarding
address and your two Gmail addresses; anything else is discarded.

## Online payment at checkout

Web orders carry `Sale__c.Payment_Method__c`: **Cash on Delivery** (default)
or **Online**. An online order is shown the UPI QR right after checkout;
the website polls `/store/v1/order-payment?ref=<web order ref>` until the
Axis credit alert books the payment, then shows a confirmation and the
payment-received WhatsApp goes out as usual. Online orders are matched by
the alert handler even while still Pending Approval.

Once an order is settled (collected > 0, balance 0) the order-confirmed,
out-for-delivery and delivered WhatsApps use the `_paid` templates, which
carry no balance line. Create these in Meta Business Manager (same header
{{1}} login code as the originals):

| Template | Body variables |
| --- | --- |
| `order_confirmed_paid` | {{1}} name, {{2}} order#, {{3}} products, {{4}} total, {{5}} delivery |
| `order_out_for_delivery_paid` | {{1}} name, {{2}} order# |
| `order_delivered_paid` | {{1}} name, {{2}} order#, {{3}} total |

Until a `_paid` template exists and is approved, Meta answers #132001 and
the code falls back to the standard template for that message, so nothing
is lost while they are pending.

