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
