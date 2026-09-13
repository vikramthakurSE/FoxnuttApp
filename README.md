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

## Colored PDF payment receipt

Every paid order gets a proper receipt: `PaymentReceiptPDF` (Visualforce,
`renderAs="pdf"`) draws a branded, colorful one-pager — status badge
(PAID / PARTIALLY PAID / UNPAID), billed-to and payment-detail cards, an
itemized order table, and the balance. `PaymentReceiptController` accepts
either `?id=<Client_Payment__c Id>` (one payment) or `?ref=<Web_Order_Ref__c>`
(an order's current state — what the website uses, since it only ever
knows its own order reference).

It's exposed publicly at `GET /store/v1/receipt?ref=…`, which returns the
raw PDF bytes (`Content-Type: application/pdf`) rather than JSON. Two
consumers:

- The website proxies it at `/api/orders/receipt?ref=` so a customer can
  download their receipt straight from the confirmation or orders page.
- `WhatsAppHelper.sendReceiptLink` (fired from the same payment dispatch as
  `payment_received`) sends a `payment_receipt` template with a **document
  header** pointing at that same website URL — Meta fetches the PDF itself,
  no media upload needed from Apex. Only web orders qualify: the receipt
  route trusts `Web_Order_Ref__c` as an unguessable token the same way
  `/order-payment` does, so a manually-entered sale (no ref) has no public
  link and is skipped rather than exposed under a guessable Id or the
  sequential order number.

Two things to set up before this reaches a customer:

1. **Custom Label `Web_Store_Base_URL`** (Setup → Custom Labels) — set it
   to the website's public URL (e.g. `https://nuttynirvana.vercel.app`).
   Left at its placeholder `unset`, the WhatsApp document is skipped
   (the website download button still works regardless — it doesn't need
   this label).
2. **WhatsApp template `payment_receipt`** in Meta Business Manager —
   header type **Document**, body `{{1}}` = client name, `{{2}}` = order
   number. Until it's approved, Meta answers #132001 and the send is
   silently skipped, same fallback pattern as the `_paid` templates.

