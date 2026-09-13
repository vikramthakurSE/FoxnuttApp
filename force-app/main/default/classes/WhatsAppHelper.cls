public class WhatsAppHelper {

    // ── Config ─────────────────────────────────────────────────────────────
    private static WhatsApp_Config__mdt getConfig() {
        List<WhatsApp_Config__mdt> cfgs = [
            SELECT Access_Token__c, Phone_Number_ID__c
            FROM WhatsApp_Config__mdt LIMIT 1
        ];
        return cfgs.isEmpty() ? null : cfgs[0];
    }

    // ── Core send ──────────────────────────────────────────────────────────
    private static void sendMessage(String payload) {
        sendMessageWithResult(payload);
    }

    /**
     * Orders that are already paid get a template with no balance line.
     * Those templates may not exist in Meta yet (they need approval), so
     * when Meta answers "template does not exist" (#132001) the standard
     * template is sent instead — a message with "balance ₹0" beats no
     * message at all.
     */
    private static void sendPaidOrStandard(String paidPayload, String stdPayload) {
        String body = sendMessageWithResult(paidPayload);
        if (body != null && body.contains('132001')) sendMessage(stdPayload);
    }

    /** Returns Meta's response body, or null when the call was not made. */
    private static String sendMessageWithResult(String payload) {
        WhatsApp_Config__mdt cfg = getConfig();
        if (cfg == null) {
            System.debug('WA: config not found'); return null;
        }
        HttpRequest req = new HttpRequest();
        req.setEndpoint(
            'https://graph.facebook.com/v19.0/' +
            cfg.Phone_Number_ID__c + '/messages'
        );
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + cfg.Access_Token__c);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(payload);
        req.setTimeout(10000);
        try {
            HttpResponse res = new Http().send(req);
            System.debug('WA [' + res.getStatusCode() + ']: ' + res.getBody());
            return res.getBody();
        } catch (Exception e) {
            System.debug('WA error: ' + e.getMessage());
            return null;
        }
    }

    /** Header value for templates that show the client's login code. */
    /** Money has come in and nothing is left to pay. */
    private static Boolean isSettled(Decimal collected, Decimal balance) {
        return collected != null && collected > 0
            && (balance == null || balance <= 0);
    }
    private static String hdr(String businessCode) {
        return String.isBlank(businessCode) ? '-' : businessCode;
    }

    // ── Format phone ───────────────────────────────────────────────────────
    private static String fmtPhone(String raw) {
        if (String.isBlank(raw)) return null;
        String d = raw.replaceAll('[^0-9]', '');
        if (d.length() == 10)        return '+91' + d;
        if (d.startsWith('0'))       return '+91' + d.substring(1);
        if (!d.startsWith('91'))     return '+91' + d;
        return d;
    }

    // ── Format quantity — show decimals for small amounts ─────────────────
    private static String fmtQty(Decimal qty) {
        if (qty == null) return '0';
        // If it's a whole number, show without decimals: 10 KG
        // If it has decimals, show with 2 decimal places: 0.25 KG
        if (qty == qty.setScale(0)) return qty.setScale(0).format();
        return qty.setScale(2).format();
    }
    private static String buildPayload(
        String to, String templateName, List<String> params
    ) {
        List<Object> parameters = new List<Object>();
        for (String p : params) {
            parameters.add(new Map<String, Object>{
                'type' => 'text',
                'text' => (p != null ? p : '-')
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'   => to,
            'type' => 'template',
            'template' => new Map<String, Object>{
                'name'     => templateName,
                'language' => new Map<String, Object>{ 'code' => 'en_US' },
                'components' => new List<Object>{
                    new Map<String, Object>{
                        'type'       => 'body',
                        'parameters' => parameters
                    }
                }
            }
        });
    }

    /** Same as buildPayload, but for templates whose approved header is an
     *  IMAGE — the API rejects the send otherwise (error 132012, format
     *  mismatch) even though the body parameters are correct. */
    /** Same as buildPayload, but for templates whose header carries a text
     *  variable — e.g. a login code shown at the top of the message. A
     *  header can hold at most one variable; it is numbered {{1}} in the
     *  header component independently of the body's own {{1}}, {{2}}, ... */
    private static String buildPayloadWithTextHeader(
        String to, String templateName, String headerText, List<String> bodyParams
    ) {
        List<Object> bodyParameters = new List<Object>();
        for (String p : bodyParams) {
            bodyParameters.add(new Map<String, Object>{
                'type' => 'text',
                'text' => (p != null ? p : '-')
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'   => to,
            'type' => 'template',
            'template' => new Map<String, Object>{
                'name'     => templateName,
                'language' => new Map<String, Object>{ 'code' => 'en_US' },
                'components' => new List<Object>{
                    new Map<String, Object>{
                        'type'       => 'header',
                        'parameters' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'text',
                                'text' => (headerText != null ? headerText : '-')
                            }
                        }
                    },
                    new Map<String, Object>{
                        'type'       => 'body',
                        'parameters' => bodyParameters
                    }
                }
            }
        });
    }

    private static String buildPayloadWithImageHeader(
        String to, String templateName, String headerImageUrl, List<String> params
    ) {
        List<Object> parameters = new List<Object>();
        for (String p : params) {
            parameters.add(new Map<String, Object>{
                'type' => 'text',
                'text' => (p != null ? p : '-')
            });
        }
        return JSON.serialize(new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'   => to,
            'type' => 'template',
            'template' => new Map<String, Object>{
                'name'     => templateName,
                'language' => new Map<String, Object>{ 'code' => 'en_US' },
                'components' => new List<Object>{
                    new Map<String, Object>{
                        'type'       => 'header',
                        'parameters' => new List<Object>{
                            new Map<String, Object>{
                                'type'  => 'image',
                                'image' => new Map<String, Object>{
                                    'link' => headerImageUrl
                                }
                            }
                        }
                    },
                    new Map<String, Object>{
                        'type'       => 'body',
                        'parameters' => parameters
                    }
                }
            }
        });
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. WELCOME — new client account created
    // Template: welcome_new_client  |  {{1}} = client name
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendWelcome(String phone, String clientName) {
        String p = fmtPhone(phone);
        if (p == null) return;
        // welcome_new_client carries only {{1}} the client's name. The
        // business ID is deliberately kept out of the welcome and sent by
        // order_pending_review or business_id_request instead.
        sendMessage(buildPayload(p, 'welcome_new_client',
            new List<String>{
                String.isBlank(clientName) ? 'there' : clientName
            }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1c. BUSINESS CODE RESEND — client asked for their code on the website
    // Template: business_id_request — {{1}} name, {{2}} business ID
    // No header: a lone alphanumeric value in the header reads as an OTP to
    // Meta's classifier and gets the template force-routed to Authentication,
    // which needs a verified business. Keep this one header-free.
    // ════════════════════════════════════════════════════════════════════════
    private static final String CODE_RESEND_TEMPLATE = 'business_id_request';

    @future(callout=true)
    public static void sendBusinessCode(
        String phone, String clientName, String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(p, CODE_RESEND_TEMPLATE,
            new List<String>{
                String.isBlank(clientName) ? 'there' : clientName,
                String.isBlank(businessCode) ? '-' : businessCode
            }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1b. ORDER PENDING — first web order from an unknown customer
    // Template: order_pending_review
    // Header {{1}} website login code — body {{1}} name, {{2}} order#
    // Header and body number their variables independently.
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderPending(
        String phone, String clientName, String saleName, String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayloadWithTextHeader(
            p, 'order_pending_review',
            String.isBlank(businessCode) ? '-' : businessCode,
            new List<String>{
                String.isBlank(clientName) ? 'there' : clientName,
                String.isBlank(saleName) ? '-' : saleName
            }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. ORDER CONFIRMED — after sale + line items saved
    // Template: order_confirmed
    // {{1}} name, {{2}} order#, {{3}} products, {{4}} total, {{5}} delivery
    // ════════════════════════════════════════════════════════════════════════
    // Paid variant: order_confirmed_paid, same variables, no payment line.
    @future(callout=true)
    public static void sendOrderConfirmed(
        String phone, String clientName, String saleName,
        String products, String total, String deliveryDate,
        String businessCode, Boolean paid
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        List<String> params = new List<String>{ clientName, saleName,
                                                products, total, deliveryDate };
        String std = buildPayloadWithTextHeader(
            p, 'order_confirmed', hdr(businessCode), params);
        if (paid == true) {
            sendPaidOrStandard(buildPayloadWithTextHeader(
                p, 'order_confirmed_paid', hdr(businessCode), params), std);
        } else {
            sendMessage(std);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 3. OUT FOR DELIVERY
    // Template: order_out_for_delivery
    // {{1}} name, {{2}} order#, {{3}} balance due
    // ════════════════════════════════════════════════════════════════════════
    // Paid variant: order_out_for_delivery_paid — {{1}} name, {{2}} order#
    @future(callout=true)
    public static void sendOutForDelivery(
        String phone, String clientName,
        String saleName, String balance, String businessCode, Boolean paid
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        String std = buildPayloadWithTextHeader(
            p, 'order_out_for_delivery', hdr(businessCode),
            new List<String>{ clientName, saleName, balance });
        if (paid == true) {
            sendPaidOrStandard(buildPayloadWithTextHeader(
                p, 'order_out_for_delivery_paid', hdr(businessCode),
                new List<String>{ clientName, saleName }), std);
        } else {
            sendMessage(std);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. ORDER DELIVERED
    // Template: order_delivered
    // {{1}} name, {{2}} order#, {{3}} total, {{4}} collected, {{5}} balance
    // ════════════════════════════════════════════════════════════════════════
    // Paid variant: order_delivered_paid — {{1}} name, {{2}} order#, {{3}} total
    @future(callout=true)
    public static void sendOrderDelivered(
        String phone, String clientName, String saleName,
        String total, String collected, String balance,
        String businessCode, Boolean paid
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        String std = buildPayloadWithTextHeader(
            p, 'order_delivered', hdr(businessCode),
            new List<String>{ clientName, saleName,
                              total, collected, balance });
        if (paid == true) {
            sendPaidOrStandard(buildPayloadWithTextHeader(
                p, 'order_delivered_paid', hdr(businessCode),
                new List<String>{ clientName, saleName, total }), std);
        } else {
            sendMessage(std);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. ORDER CANCELLED
    // Template: order_cancelled
    // {{1}} name, {{2}} order#
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderCancelled(
        String phone, String clientName, String saleName,
        String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayloadWithTextHeader(
            p, 'order_cancelled', hdr(businessCode),
            new List<String>{ clientName, saleName }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5b. ORDER MODIFIED — customer changed a live order on the website
    // Template: order_modified — header {{1}} login code
    // Body {{1}} name, {{2}} order#, {{3}} products, {{4}} new total
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendOrderModified(
        String phone, String clientName, String saleName,
        String products, String total, String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayloadWithTextHeader(
            p, 'order_modified', hdr(businessCode),
            new List<String>{ clientName, saleName, products, total }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 6. PAYMENT RECEIVED
    // Template: payment_received
    // {{1}} name, {{2}} amount, {{3}} order#, {{4}} remaining balance
    // This template has NO header in Meta. Sending a header parameter makes
    // Meta reject the whole message (#132000), so the business code is
    // left out here until the template gains a header.
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendPaymentReceived(
        String phone, String clientName, String amount,
        String saleName, String remainingBalance, String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayload(
            p, 'payment_received',
            new List<String>{ clientName, amount,
                              saleName, remainingBalance }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 7. ORDER FOLLOW-UP REMINDER (21+ days no order)
    // Template: order_followup_reminder — header {{1}} website login code
    // Body {{1}} name, {{2}} last order date, {{3}} stock + prices block.
    // Header and body number their variables independently. The header used
    // to carry the branded photo (FOLLOWUP_HEADER_IMAGE_URL below, kept in
    // case that trade is reversed) — a header can only be one type, so
    // showing the code here means the photo no longer appears on this
    // message.
    // ════════════════════════════════════════════════════════════════════════
    private static final String FOLLOWUP_HEADER_IMAGE_URL =
        'https://drive.google.com/uc?export=download&id=1vJpyG9QHyTJLLZ6P96zT7G3I6W6ODGd7';

    @future(callout=true)
    public static void sendOrderFollowUp(
        String phone, String clientName, String lastOrderDate,
        String stockBlock, String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayloadWithTextHeader(
            p, 'order_followup_reminder',
            String.isBlank(businessCode) ? '-' : businessCode,
            new List<String>{ clientName, lastOrderDate, stockBlock }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // 8. PAYMENT FOLLOW-UP REMINDER (21+ days pending)
    // Template: payment_followup_reminder
    // {{1}} name, {{2}} amount due, {{3}} order#, {{4}} days pending
    // ════════════════════════════════════════════════════════════════════════
    @future(callout=true)
    public static void sendPaymentFollowUp(
        String phone, String clientName, String amountDue,
        String saleName, String daysPending, String businessCode
    ) {
        String p = fmtPhone(phone);
        if (p == null) return;
        sendMessage(buildPayloadWithTextHeader(
            p, 'payment_followup_reminder', hdr(businessCode),
            new List<String>{ clientName, amountDue,
                              saleName, daysPending }));
    }

    // ════════════════════════════════════════════════════════════════════════
    // DISPATCHER METHODS — called from triggers/schedulers
    // Each collects data and calls the @future method above
    // ════════════════════════════════════════════════════════════════════════

    // ── 1. Welcome — called from AccountTrigger ────────────────────────────
    public static void dispatchWelcome(List<Account> accounts) {
        for (Account a : accounts) {
            if (String.isBlank(a.Phone)) continue;
            sendWelcome(a.Phone, a.Name);
        }
    }

    // ── 1b. Order Pending — called from SaleLineItemHelper.onInsert ───────
    public static void dispatchOrderPending(List<Sale__c> sales) {
        for (Sale__c s : sales) {
            if (String.isBlank(s.Client__r?.Phone)) continue;
            sendOrderPending(
                s.Client__r.Phone, s.Client__r.Name, s.Name,
                s.Client__r.Unique_Business_Code__c
            );
        }
    }

    // ── 2. Order Confirmed — called from SaleLineItemHelper.onInsert ───────
    public static void dispatchOrderConfirmed(
        List<Sale__c> sales,
        Map<Id, List<Sale_Line_Item__c>> liMap
    ) {
        // Callers' queries predate the payment fields; a web order paid
        // online before approval must not be told to keep cash ready.
        Map<Id, Sale__c> payState = new Map<Id, Sale__c>([
            SELECT Id, Total_Collected__c, Balance_Due__c
            FROM Sale__c WHERE Id IN :sales
        ]);
        for (Sale__c s : sales) {
            if (String.isBlank(s.Client__r?.Phone)) continue;
            Sale__c ps = payState.get(s.Id);
            Boolean paid = ps != null && isSettled(ps.Total_Collected__c,
                                                   ps.Balance_Due__c);

            List<Sale_Line_Item__c> items = liMap.containsKey(s.Id)
                ? liMap.get(s.Id) : new List<Sale_Line_Item__c>();

            String products = '';
            Decimal total   = 0;
            for (Sale_Line_Item__c li : items) {
                Decimal qty  = li.Quantity__c    != null ? li.Quantity__c    : 0;
                Decimal rate = li.Rate_Per_Kg__c != null ? li.Rate_Per_Kg__c : 0;
                total += qty * rate;
                if (products != '') products += ', ';
                products += li.Brand__c + ' ' +
                    fmtQty(qty) + ' KG @ Rs' + rate.setScale(0);
            }

            String delivery = s.Expected_Delivery_Date__c != null
                ? s.Expected_Delivery_Date__c.format() : 'To be confirmed';

            sendOrderConfirmed(
                s.Client__r.Phone, s.Client__r.Name, s.Name,
                products,
                total.setScale(2).format(),
                delivery,
                s.Client__r.Unique_Business_Code__c,
                paid
            );
        }
    }

    // ── 3/4/5. Status Updates — called from SaleTrigger ───────────────────
    public static void dispatchStatusUpdate(List<Sale__c> sales) {
        for (Sale__c s : sales) {
            if (String.isBlank(s.Client__r?.Phone)) continue;

            String status = s.Order_Status__c;
            Decimal rev   = s.Total_Revenue__c    != null ? s.Total_Revenue__c    : 0;
            Decimal col   = s.Total_Collected__c  != null ? s.Total_Collected__c  : 0;
            Decimal bal   = s.Balance_Due__c      != null ? s.Balance_Due__c      : 0;
            Boolean paid  = isSettled(col, bal);

            if (status == 'Out for Delivery') {
                sendOutForDelivery(
                    s.Client__r.Phone, s.Client__r.Name, s.Name,
                    bal.setScale(0).format(),
                    s.Client__r.Unique_Business_Code__c,
                    paid
                );
            } else if (status == 'Delivered') {
                sendOrderDelivered(
                    s.Client__r.Phone, s.Client__r.Name, s.Name,
                    'Rs ' + rev.setScale(0).format(),
                    'Rs ' + col.setScale(0).format(),
                    bal.setScale(0).format(),
                    s.Client__r.Unique_Business_Code__c,
                    paid
                );
            } else if (status == 'Cancelled') {
                sendOrderCancelled(
                    s.Client__r.Phone, s.Client__r.Name, s.Name,
                    s.Client__r.Unique_Business_Code__c
                );
            }
        }
    }

    // ── 6. Payment Received — called from ClientPaymentSummaryTrigger ──────
    public static void dispatchPaymentReceived(
        List<Client_Payment__c> payments,
        Map<Id, Sale__c> saleMap
    ) {
        for (Client_Payment__c p : payments) {
            Sale__c s = saleMap.get(p.Sale__c);
            if (s == null || String.isBlank(s.Client__r?.Phone)) continue;

            Decimal amt = p.Amount__c       != null ? p.Amount__c       : 0;
            Decimal bal = s.Balance_Due__c  != null ? s.Balance_Due__c  : 0;

            sendPaymentReceived(
                s.Client__r.Phone, s.Client__r.Name,
                amt.setScale(0).format(),
                s.Name,
                bal.setScale(0).format(),
                s.Client__r.Unique_Business_Code__c
            );
        }
    }

    // Called from ClientPaymentSummaryTrigger. Runs @future so it fires AFTER
    // the Settlement_Amount roll-up into Sale.Total_Collected has committed —
    // otherwise Balance_Due__c is read stale and (with a cash discount) still
    // shows the pre-payment balance to the client.
    @future(callout=true)
    public static void dispatchPaymentReceivedAsync(Set<Id> paymentIds) {
        for (Client_Payment__c p : [
            SELECT Amount__c, Sale__r.Name, Sale__r.Balance_Due__c,
                   Sale__r.Web_Order_Ref__c,
                   Sale__r.Client__r.Name, Sale__r.Client__r.Phone,
                   Sale__r.Client__r.Unique_Business_Code__c
            FROM Client_Payment__c
            WHERE Id IN :paymentIds
        ]) {
            if (p.Sale__r == null
                || String.isBlank(p.Sale__r.Client__r?.Phone)) continue;

            String ph = fmtPhone(p.Sale__r.Client__r.Phone);
            if (ph == null) continue;

            Decimal amt = p.Amount__c != null ? p.Amount__c : 0;
            Decimal bal = p.Sale__r.Balance_Due__c != null
                          ? p.Sale__r.Balance_Due__c : 0;
            if (bal < 0) bal = 0;   // a CD over-settlement shows as ₹0, not negative

            // No header: see sendPaymentReceived.
            sendMessage(buildPayload(ph, 'payment_received',
                new List<String>{
                    p.Sale__r.Client__r.Name,
                    amt.setScale(0).format(),
                    p.Sale__r.Name,
                    bal.setScale(0).format()
                }));

            sendReceiptLink(ph, p.Sale__r.Client__r.Unique_Business_Code__c,
                p.Sale__r.Name, p.Sale__r.Web_Order_Ref__c);
        }
    }

    // ── Receipt PDF link — only for web orders (Web_Order_Ref__c is the
    // unguessable token the public /api/orders/receipt route trusts; a
    // manually-entered sale has none, so it is skipped rather than exposed
    // under a guessable Id or sequential order number).
    // Template: payment_receipt — header DOCUMENT (sent as {"link": ...}),
    // body {{1}} order#. Silently does nothing until both the
    // Web_Store_Base_URL custom label is set and the template is approved
    // in Meta (a missing template answers #132001, same as the _paid
    // fallbacks elsewhere in this class).
    private static void sendReceiptLink(
        String phone, String businessCode, String saleName, String orderRef
    ) {
        if (String.isBlank(orderRef)) return;
        String base = Label.Web_Store_Base_URL;
        if (String.isBlank(base) || base == 'unset') return;
        String link = base.removeEnd('/') +
            '/api/orders/receipt?ref=' + EncodingUtil.urlEncode(orderRef, 'UTF-8');

        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'   => phone,
            'type' => 'template',
            'template' => new Map<String, Object>{
                'name'     => 'payment_receipt',
                'language' => new Map<String, Object>{ 'code' => 'en_US' },
                'components' => new List<Object>{
                    new Map<String, Object>{
                        'type' => 'header',
                        'parameters' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'document',
                                'document' => new Map<String, Object>{
                                    'link' => link,
                                    'filename' => (String.isBlank(saleName)
                                        ? 'Receipt' : saleName) + '.pdf'
                                }
                            }
                        }
                    },
                    new Map<String, Object>{
                        'type' => 'body',
                        'parameters' => new List<Object>{
                            new Map<String, Object>{
                                'type' => 'text',
                                'text' => String.isBlank(saleName) ? '-' : saleName
                            }
                        }
                    }
                }
            }
        };
        sendMessage(JSON.serialize(payload));
    }

    // ── 7. Order Follow-Up — called from FollowUpNotificationHelper ─────────
    // Builds live stock block from Inventory with Selling_Price__c
    public static void dispatchOrderFollowUp(
        String phone, String clientName, String lastOrderDate,
        String businessCode
    ) {
        if (String.isBlank(phone)) return;

        // Brand names only — no price, no stock quantity. Prices vary per
        // client, so quoting one figure over WhatsApp would be misleading.
        Set<String> brandSet = new Set<String>();
        for (Inventory__c inv : [
            SELECT Brand__c
            FROM Inventory__c
            WHERE Remaining_Quantity__c > 0
            AND   Selling_Price__c != null
            ORDER BY Brand__c
        ]) {
            brandSet.add(inv.Brand__c);
        }
        List<String> brandNames = new List<String>(brandSet);
        brandNames.sort();
        String stockBlock = brandNames.isEmpty()
            ? 'Fresh stock available. Contact us for details.'
            : String.join(brandNames, ' | ');

        // Trim to fit WA limit
        if (stockBlock.length() > 300)
            stockBlock = stockBlock.substring(0, 297) + '...';

        sendOrderFollowUp(
            phone, clientName, lastOrderDate, stockBlock, businessCode
        );
    }

    // ── 8. Payment Follow-Up — called from PaymentReminderHelper ───────────
    public static void dispatchPaymentFollowUp(
        String phone, String clientName, String amountDue,
        String saleName, Integer daysOld, String businessCode
    ) {
        if (String.isBlank(phone)) return;
        sendPaymentFollowUp(
            phone, clientName, amountDue,
            saleName, String.valueOf(daysOld), businessCode
        );
    }
}