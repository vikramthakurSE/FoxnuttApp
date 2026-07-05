public class EmailNotificationHelper {

    // ── Get all active System Admin emails ─────────────────────────────────
    private static List<String> getAdminEmails() {
        List<String> emails = new List<String>{'vikramthakur381@gmail.com','rohanagarwalprp@gmail.com'};
        return emails;
    }

    // ── Core send method ───────────────────────────────────────────────────
    // Sends ONE separate email per recipient — fixes DE delivery issue
    // where setToAddresses with multiple recipients only delivers to first
    private static void sendEmail(
        String subject, String htmlBody, List<String> toAddresses
    ) {
        if (toAddresses == null || toAddresses.isEmpty()) return;

        List<OrgWideEmailAddress> owas = [
            SELECT Id FROM OrgWideEmailAddress LIMIT 1
        ];

        List<Messaging.SingleEmailMessage> mails =
            new List<Messaging.SingleEmailMessage>();

        for (String addr : toAddresses) {
            if (String.isBlank(addr)) continue;
            Messaging.SingleEmailMessage mail =
                new Messaging.SingleEmailMessage();
            mail.setToAddresses(new List<String>{ addr });
            mail.setSubject(subject);
            mail.setHtmlBody(htmlBody);
            mail.setSaveAsActivity(false);
            if (!owas.isEmpty()) {
                mail.setOrgWideEmailAddressId(owas[0].Id);
            }
            mails.add(mail);
        }

        if (!mails.isEmpty()) {
            try {
                Messaging.sendEmail(mails);
            } catch (Exception e) {
                System.debug('Email send failed: ' + e.getMessage());
            }
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 1. NEW PURCHASE — fires from PurchaseLineItemTrigger after insert
    // ════════════════════════════════════════════════════════════════════════
    public static void sendNewPurchaseAlert(
        List<Purchase_Line_Item__c> lineItems
    ) {
        if (lineItems.isEmpty()) return;

        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : lineItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }

        // FIX: query Tax_Amount__c; Total_Order_Cost__c may still be 0
        // (Roll-Up hasn't committed) — we compute total from line items
        Map<Id, Purchase__c> purchases = new Map<Id, Purchase__c>([
            SELECT Id, Name, Unique_Order_Code__c,
                   Supplier__r.Name, Order_Date__c,
                   Quarter__c, Delivery_Status__c,
                   Total_Order_Cost__c, Total_Paid__c,
                   Tax_Amount__c, Amount_Outstanding__c,
                   Manufacturer_Payment_Status__c
            FROM Purchase__c
            WHERE Id IN :purchaseIds
        ]);

        // Group line items per purchase
        Map<Id, List<Purchase_Line_Item__c>> liMap =
            new Map<Id, List<Purchase_Line_Item__c>>();
        for (Purchase_Line_Item__c li : lineItems) {
            if (!liMap.containsKey(li.Purchase__c))
                liMap.put(li.Purchase__c, new List<Purchase_Line_Item__c>());
            liMap.get(li.Purchase__c).add(li);
        }

        List<String> admins = getAdminEmails();

        for (Id purId : liMap.keySet()) {
            Purchase__c p = purchases.get(purId);
            if (p == null) continue;

            List<Purchase_Line_Item__c> items = liMap.get(purId);

            // Compute order cost from line items (Roll-Up may be stale)
            Decimal computedOrderCost = 0;
            String itemRows = '';
            for (Purchase_Line_Item__c li : items) {
                Decimal qty  = li.Quantity__c != null ? li.Quantity__c : 0;
                Decimal cost = li.Landing_Cost_Per_Kg__c != null
                               ? li.Landing_Cost_Per_Kg__c : 0;
                Decimal total = qty * cost;
                computedOrderCost += total;
                itemRows +=
                    '<tr>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;">' + li.Brand__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' + li.Packet_Type__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' + qty + ' KG</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:right;">₹' + cost + '/kg</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:600;color:#111;text-align:right;">₹' + total.setScale(2) + '</td>' +
                    '</tr>';
            }

            Decimal tax = p.Tax_Amount__c != null ? p.Tax_Amount__c : 0;

            String html = buildPurchaseAlertEmail(
                p, itemRows, computedOrderCost, tax
            );
            String subject = '🛒 New Purchase Order — ' + p.Name +
                ' | ' + p.Supplier__r.Name;
            sendEmail(subject, html, admins);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 2. PURCHASE STATUS CHANGED — fires from PurchaseTrigger after update
    // ════════════════════════════════════════════════════════════════════════
    public static void sendPurchaseStatusChanged(
        List<Purchase__c> purchases
    ) {
        List<String> admins = getAdminEmails();
        for (Purchase__c p : purchases) {
            Boolean isReceived = p.Delivery_Status__c == 'Received';
            String subject = isReceived
                ? '✅ GOODS RECEIVED — ' + p.Name + ' | Verify Stock Now'
                : 'Purchase Status Updated — ' + p.Name +
                  ' is now ' + p.Delivery_Status__c;
            String html = isReceived
                ? buildGoodsReceivedEmail(p)
                : buildStatusChangedEmail(p);
            sendEmail(subject, html, admins);
        }
    }


    // ════════════════════════════════════════════════════════════════════════
    // 3b. NEW SALE — fires from SaleLineItemHelper after insert
    // ════════════════════════════════════════════════════════════════════════
    public static void sendNewSaleAlert(
        List<Sale_Line_Item__c> lineItems
    ) {
        if (lineItems.isEmpty()) return;

        Set<Id> saleIds = new Set<Id>();
        for (Sale_Line_Item__c li : lineItems) {
            if (li.Sale__c != null) saleIds.add(li.Sale__c);
        }

        Map<Id, Sale__c> sales = new Map<Id, Sale__c>([
            SELECT Id, Name, Sale_Date__c, Order_Status__c,
                   Regional_Manager__c, Total_Revenue__c,
                   Balance_Due__c, Payment_Status__c,
                   Client__r.Name
            FROM Sale__c WHERE Id IN :saleIds
        ]);

        Map<Id, List<Sale_Line_Item__c>> liMap =
            new Map<Id, List<Sale_Line_Item__c>>();
        for (Sale_Line_Item__c li : lineItems) {
            if (!liMap.containsKey(li.Sale__c))
                liMap.put(li.Sale__c, new List<Sale_Line_Item__c>());
            liMap.get(li.Sale__c).add(li);
        }

        List<String> admins = getAdminEmails();

        for (Id saleId : liMap.keySet()) {
            Sale__c s = sales.get(saleId);
            if (s == null) continue;

            String itemRows = '';
            for (Sale_Line_Item__c li : liMap.get(saleId)) {
                Decimal qty  = li.Quantity__c != null ? li.Quantity__c : 0;
                Decimal rate = li.Rate_Per_Kg__c != null ? li.Rate_Per_Kg__c : 0;
                Decimal lineAmt = qty * rate;
                itemRows +=
                    '<tr>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;">' + li.Brand__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' + li.Packet_Type__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' + qty + ' KG</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:right;">₹' + rate + '/kg</td>' +
                    '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:600;color:#111;text-align:right;">₹' + lineAmt.setScale(2) + '</td>' +
                    '</tr>';
            }

            String body =
                '<p style="font-size:14px;color:#374151;line-height:1.6;margin:0 0 20px;">A new sale has been recorded.</p>' +
                card('Sale Details',
                    kv('Sale Number', s.Name, '') +
                    kv('Client', s.Client__r.Name, '') +
                    kv('Sale Date', s.Sale_Date__c != null ? s.Sale_Date__c.format() : '—', '') +
                    kv('Handled By', s.Regional_Manager__c != null ? s.Regional_Manager__c : '—', '') +
                    kvLast('Status', s.Order_Status__c, '#d97706')
                ) +
                '<table width="100%" cellpadding="0" cellspacing="0" ' +
                'style="background:#f9fafb;border-radius:10px;margin-bottom:16px;overflow:hidden;">' +
                '<tr>' + th('Brand') + th('Type') + th('Qty') + th('Rate') + th('Total') + '</tr>' +
                itemRows + '</table>';

            sendEmail(
                '🛒 New Sale — ' + s.Name + ' | ' + s.Client__r.Name,
                wrap('#1e1b4b', '#a78bfa', 'NEW SALE', '#312e81', '#c4b5fd',
                     'Sale Recorded', s.Name + ' · ' + s.Client__r.Name,
                     body, '#faf5ff', '#c4b5fd'),
                admins
            );
        }
    }


    // ════════════════════════════════════════════════════════════════════════
    // 3c. SALE STATUS CHANGED (Confirmed / Out for Delivery / Cancelled)
    // ════════════════════════════════════════════════════════════════════════
    // 3c. SALE STATUS CHANGED (Confirmed / Out for Delivery / Cancelled)
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSaleStatusChanged(List<Sale__c> sales) {
        List<String> admins = getAdminEmails();

        for (Sale__c s : sales) {
            String status = s.Order_Status__c;

            String hBg  = '#1e1b4b';
            String badge = 'STATUS UPDATE';

            if (status == 'Out for Delivery') {
                hBg   = '#7c3a00';
                badge = 'OUT FOR DELIVERY';
            } else if (status == 'Cancelled') {
                hBg   = '#450a0a';
                badge = 'CANCELLED';
            } else if (status == 'Confirmed') {
                hBg   = '#052e16';
                badge = 'CONFIRMED';
            }

            Decimal rev = s.Total_Revenue__c != null ? s.Total_Revenue__c : 0;
            Decimal bal = s.Balance_Due__c   != null ? s.Balance_Due__c   : 0;

            // Balance row — no ternary inside string concat
            String balanceRow;
            if (status == 'Cancelled') {
                balanceRow = kvLast('Balance Due', 'Rs 0.00 — Cancelled', '#6b7280');
            } else if (bal > 0) {
                balanceRow = kvLast('Balance Due', 'Rs ' + bal.setScale(2), '#dc2626');
            } else {
                balanceRow = kvLast('Balance Due', 'Rs 0.00', '#16a34a');
            }

            // Action box — plain if/else, no nested ternary
            String actionBox = '';
            if (status == 'Out for Delivery') {
                actionBox  = '<table width="100%" cellpadding="0" cellspacing="0" ';
                actionBox += 'style="background:#fff7ed;border-radius:10px;';
                actionBox += 'border-left:4px solid #f59e0b;margin-top:12px;">';
                actionBox += '<tr><td style="padding:16px 20px;">';
                actionBox += '<div style="font-size:10px;font-weight:700;text-transform:uppercase;';
                actionBox += 'color:#92400e;margin-bottom:8px;">ACTION REQUIRED</div>';
                actionBox += '<p style="font-size:12px;color:#374151;margin:0 0 6px;">';
                actionBox += 'Order is on the way to ' + s.Client__r.Name + '.</p>';
                actionBox += '<p style="font-size:12px;color:#374151;margin:0 0 6px;">';
                actionBox += 'Update status to Delivered once handed over.</p>';
                actionBox += '<p style="font-size:12px;color:#374151;margin:0;">';
                actionBox += 'Collect Rs ' + bal.setScale(2) + ' on delivery.</p>';
                actionBox += '</td></tr></table>';
            } else if (status == 'Cancelled') {
                actionBox  = '<table width="100%" cellpadding="0" cellspacing="0" ';
                actionBox += 'style="background:#fef2f2;border-radius:10px;';
                actionBox += 'border-left:4px solid #ef4444;margin-top:12px;">';
                actionBox += '<tr><td style="padding:16px 20px;">';
                actionBox += '<div style="font-size:10px;font-weight:700;text-transform:uppercase;';
                actionBox += 'color:#991b1b;margin-bottom:8px;">ORDER CANCELLED</div>';
                actionBox += '<p style="font-size:12px;color:#374151;margin:0;">';
                actionBox += 'This order has been cancelled. ';
                actionBox += 'No payment due. Stock returned to inventory.</p>';
                actionBox += '</td></tr></table>';
            }

            // Build body
            String body = '';
            body += '<p style="font-size:14px;color:#374151;line-height:1.6;';
            body += 'margin:0 0 20px;">A sale order status has been updated.</p>';
            body += '<table width="100%" cellpadding="0" cellspacing="0" ';
            body += 'style="background:#1f2937;border-radius:10px;margin-bottom:16px;">';
            body += '<tr><td style="padding:20px 24px;text-align:center;">';
            body += '<div style="font-size:11px;font-weight:700;color:#6b7280;';
            body += 'text-transform:uppercase;letter-spacing:.1em;margin-bottom:8px;">';
            body += 'CURRENT STATUS</div>';
            body += '<div style="font-size:26px;font-weight:900;color:#f9fafb;">';
            body += status + '</div>';
            body += '</td></tr></table>';
            body += '<table width="100%" cellpadding="0" cellspacing="0" ';
            body += 'style="background:#f9fafb;border-radius:10px;margin-bottom:12px;">';
            body += '<tr><td style="padding:18px 20px;">';
            body += '<div style="font-size:10px;font-weight:700;text-transform:uppercase;';
            body += 'letter-spacing:.08em;color:#9ca3af;margin-bottom:12px;">SALE DETAILS</div>';
            body += '<table width="100%" cellpadding="0" cellspacing="0">';
            body += kv('Sale Number', s.Name, '');
            body += kv('Client', s.Client__r.Name, '');
            body += kv('Sale Date', s.Sale_Date__c != null ? s.Sale_Date__c.format() : '-', '');
            body += kv('Handled By', s.Regional_Manager__c != null ? s.Regional_Manager__c : '-', '');
            body += kv('Total Revenue', 'Rs ' + rev.setScale(2), '');
            body += balanceRow;
            body += '</table></td></tr></table>';
            body += actionBox;

            String subject = '[' + status + '] ' + s.Name + ' | ' + s.Client__r.Name;

            sendEmail(
                subject,
                wrap(hBg, '#f9fafb',
                     badge, '#374151', '#d1d5db',
                     'Sale Status: ' + status,
                     s.Name + ' - ' + s.Client__r.Name,
                     body, '#f8fafc', '#94a3b8'),
                admins
            );
        }
    }
    // ════════════════════════════════════════════════════════════════════════
    // 3. SALE DELIVERED — fires from SaleTrigger after update
    // ════════════════════════════════════════════════════════════════════════
    public static void sendSaleDelivered(List<Sale__c> sales) {
        List<String> admins = getAdminEmails();
        for (Sale__c s : sales) {
            String subject = '🚚 Delivered — ' + s.Name +
                ' | ' + s.Client__r.Name +
                ' | Balance: ₹' + (s.Balance_Due__c != null
                    ? s.Balance_Due__c.setScale(2) : 0.00);
            sendEmail(subject, buildSaleDeliveredEmail(s), admins);
        }
    }

    // ════════════════════════════════════════════════════════════════════════
    // 4. CLIENT PAYMENT RECEIVED — fires from ClientPaymentSummaryTrigger
    // ════════════════════════════════════════════════════════════════════════
    // Uses @future so Roll-Up fields (Total_Collected, Balance_Due)
    // have time to commit before the email is built and sent.
    public static void sendPaymentReceived(
        List<Client_Payment__c> payments
    ) {
        Set<Id> paymentIds = new Set<Id>();
        for (Client_Payment__c p : payments) {
            if (p.Id != null) paymentIds.add(p.Id);
        }
        if (!paymentIds.isEmpty()) {
            sendPaymentReceivedAsync(paymentIds);
        }
    }

    @future
    private static void sendPaymentReceivedAsync(Set<Id> paymentIds) {
        // Re-query payments fresh
        List<Client_Payment__c> payments = [
            SELECT Id, Amount__c, Mode_of_Payment__c, Accepted_By__c,
                   Payment_Date__c, Reference__c, Sale__c
            FROM Client_Payment__c
            WHERE Id IN :paymentIds
        ];

        Set<Id> saleIds = new Set<Id>();
        for (Client_Payment__c p : payments) {
            if (p.Sale__c != null) saleIds.add(p.Sale__c);
        }

        // Re-query Sale fresh — Roll-Up has now committed
        Map<Id, Sale__c> sales = new Map<Id, Sale__c>([
            SELECT Id, Name, Sale_Date__c,
                   Total_Revenue__c, Total_Collected__c,
                   Balance_Due__c, Payment_Status__c,
                   Client__r.Name
            FROM Sale__c WHERE Id IN :saleIds
        ]);

        List<String> admins = getAdminEmails();

        for (Client_Payment__c p : payments) {
            Sale__c s = sales.get(p.Sale__c);
            if (s == null) continue;

            Decimal amt = p.Amount__c != null ? p.Amount__c : 0;
            String subject = 'Payment Received — Rs ' +
                amt.setScale(2) + ' from ' + s.Client__r.Name;

            sendEmail(subject, buildPaymentReceivedEmail(p, s), admins);
        }

        // Push notification — same payments, fresh sale data
        NotificationHelper.notifyPaymentReceived(payments, sales);
    }

    // ════════════════════════════════════════════════════════════════════════
    // 5. WEEKLY PENDING — called from WeeklyPendingPaymentsScheduler
    // ════════════════════════════════════════════════════════════════════════
    public static void sendWeeklyPendingPayments() {
        List<Sale__c> pending = [
            SELECT Id, Name, Sale_Date__c,
                   Client__r.Name, Balance_Due__c,
                   Payment_Status__c, Regional_Manager__c
            FROM Sale__c
            WHERE Payment_Status__c != 'Fully Paid'
            AND Order_Status__c = 'Delivered'
            AND Order_Status__c != 'Cancelled'
            AND Balance_Due__c > 0
            ORDER BY Balance_Due__c DESC
            LIMIT 50
        ];
        if (pending.isEmpty()) return;

        Decimal totalPending = 0;
        String rows = '';
        for (Sale__c s : pending) {
            Decimal bal = s.Balance_Due__c != null ? s.Balance_Due__c : 0;
            totalPending += bal;
            rows +=
                '<tr>' +
                '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;">' + s.Client__r.Name + '</td>' +
                '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' + s.Name + '</td>' +
                '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' +
                (s.Sale_Date__c != null ? s.Sale_Date__c.format() : '—') +
                '</td>' +
                '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;color:#374151;text-align:center;">' +
                (s.Regional_Manager__c != null ? s.Regional_Manager__c : '—') + '</td>' +
                '<td style="padding:8px 12px;border-bottom:1px solid #f0f0f0;font-size:12px;font-weight:700;color:#dc2626;text-align:right;">₹' +
                bal.setScale(2) + '</td>' +
                '</tr>';
        }

        List<String> admins = getAdminEmails();
        String subject = '📋 Weekly Pending Payments — ' +
            pending.size() + ' clients | Total: ₹' +
            totalPending.setScale(2);
        sendEmail(subject,
            buildWeeklyPendingEmail(rows, pending.size(), totalPending),
            admins);
    }

    // ════════════════════════════════════════════════════════════════════════
    // EMAIL BODY BUILDERS
    // ════════════════════════════════════════════════════════════════════════

    // ── Shared helpers ──────────────────────────────────────────────────────
    private static String card(String title, String rows) {
        return
        '<table width="100%" cellpadding="0" cellspacing="0" ' +
        'style="background:#f9fafb;border-radius:10px;margin-bottom:16px;">' +
        '<tr><td style="padding:18px 20px;">' +
        '<div style="font-size:10px;font-weight:700;text-transform:uppercase;' +
        'letter-spacing:.08em;color:#9ca3af;margin-bottom:12px;">' + title + '</div>' +
        '<table width="100%" cellpadding="0" cellspacing="0">' +
        rows + '</table>' +
        '</td></tr></table>';
    }

    private static String kv(String label, String value, String valColor) {
        return
        '<tr>' +
        '<td style="padding:6px 0;border-bottom:1px solid #f0f0f0;' +
        'font-size:12px;color:#9ca3af;">' + label + '</td>' +
        '<td align="right" style="padding:6px 0;border-bottom:1px solid #f0f0f0;' +
        'font-size:12px;font-weight:600;color:' +
        (String.isBlank(valColor) ? '#111' : valColor) + ';">' +
        value + '</td>' +
        '</tr>';
    }

    private static String kvLast(String label, String value, String valColor) {
        return
        '<tr>' +
        '<td style="padding:6px 0;font-size:12px;color:#9ca3af;">' + label + '</td>' +
        '<td align="right" style="padding:6px 0;font-size:12px;font-weight:600;color:' +
        (String.isBlank(valColor) ? '#111' : valColor) + ';">' +
        value + '</td>' +
        '</tr>';
    }

    private static String th(String label) {
        return
        '<th style="padding:10px 12px;background:#f3f4f6;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;letter-spacing:.06em;' +
        'color:#6b7280;text-align:left;border-bottom:1px solid #e5e7eb;">' +
        label + '</th>';
    }

    private static String wrap(
        String hBg, String hColor, String badge, String badgeBg, String badgeColor,
        String title, String subtitle, String body,
        String fBg, String fColor
    ) {
        return
        '<!DOCTYPE html><html><body style="margin:0;padding:0;background:#f5f5f5;' +
        'font-family:Helvetica Neue,Arial,sans-serif;">' +
        '<table width="100%" cellpadding="0" cellspacing="0">' +
        '<tr><td align="center" style="padding:24px 16px;">' +
        '<table width="580" cellpadding="0" cellspacing="0" ' +
        'style="background:#fff;border-radius:12px;overflow:hidden;' +
        'box-shadow:0 4px 24px rgba(0,0,0,.08);max-width:580px;">' +
        '<tr><td style="background:' + hBg + ';padding:24px 32px;">' +
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
        '<td style="font-size:13px;font-weight:700;color:' + hColor + ';' +
        'letter-spacing:.04em;text-transform:uppercase;">🌾 Makhana Co.</td>' +
        '<td align="right"><span style="background:' + badgeBg + ';color:' +
        badgeColor + ';font-size:10px;font-weight:600;padding:4px 10px;' +
        'border-radius:20px;">' + badge + '</span></td>' +
        '</tr></table></td></tr>' +
        '<tr><td style="background:' + hBg + ';padding:0 32px 28px;">' +
        '<div style="font-size:22px;font-weight:700;color:#fff;line-height:1.3;' +
        'margin-bottom:4px;">' + title + '</div>' +
        '<div style="font-size:12px;color:' + hColor + ';opacity:.6;">' +
        subtitle + '</div></td></tr>' +
        '<tr><td style="height:1px;background:#e5e7eb;font-size:0;">&nbsp;</td></tr>' +
        '<tr><td style="padding:28px 32px;">' + body + '</td></tr>' +
        '<tr><td style="height:1px;background:#f3f4f6;font-size:0;">&nbsp;</td></tr>' +
        '<tr><td style="background:' + fBg + ';padding:16px 32px 20px;">' +
        '<p style="font-size:11px;color:' + fColor + ';margin:0;line-height:1.6;">' +
        'Automated notification · <strong>Makhana Business App</strong>' +
        '</p></td></tr>' +
        '</table></td></tr></table></body></html>';
    }

    // ── Email 1: New Purchase ────────────────────────────────────────────────
    private static String buildPurchaseAlertEmail(
        Purchase__c p, String itemRows,
        Decimal computedOrderCost, Decimal tax
    ) {
        Decimal totalDue = computedOrderCost + tax;
        Decimal paid     = p.Total_Paid__c != null ? p.Total_Paid__c : 0;
        Decimal stillOwed = Math.max(0, totalDue - paid);

        String taxRow = tax > 0
            ? kv('+ Tax Paid',
                '<span style="color:#d97706;">₹' + tax.setScale(2) + '</span>',
                '#d97706')
            : '';

        String totalDueRow = tax > 0
            ? '<tr><td style="padding:8px 0;border-bottom:1px solid #f0f0f0;' +
              'border-top:1px solid #e5e7eb;font-size:12px;color:#9ca3af;">' +
              'Total Due to Mfr</td>' +
              '<td align="right" style="padding:8px 0;border-bottom:1px solid #f0f0f0;' +
              'border-top:1px solid #e5e7eb;font-size:13px;font-weight:900;color:#111;">' +
              '₹' + totalDue.setScale(2) + '</td></tr>'
            : '';

        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A new purchase order has been placed. ' +
            'Line items are shown below.</p>' +

            card('Order Details',
                kv('Order Number', p.Name, '') +
                kv('Order Code',
                    p.Unique_Order_Code__c != null ? p.Unique_Order_Code__c : '—', '') +
                kv('Supplier', p.Supplier__r.Name, '') +
                kv('Order Date',
                    p.Order_Date__c != null ? p.Order_Date__c.format() : '—', '') +
                kv('Quarter',
                    p.Quarter__c != null ? p.Quarter__c : '—', '') +
                kvLast('Status', p.Delivery_Status__c, '#d97706')
            ) +

            // Line items table
            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f9fafb;border-radius:10px;margin-bottom:16px;overflow:hidden;">' +
            '<tr>' + th('Brand') + th('Type') + th('Qty') + th('Rate') + th('Total') + '</tr>' +
            itemRows +
            '</table>' +

            // Financial breakdown — Order Cost + Tax + Total Due
            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f0fdf4;border-radius:10px;margin-bottom:16px;">' +
            '<tr><td style="padding:18px 22px;">' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;' +
            'letter-spacing:.08em;color:#16a34a;margin-bottom:12px;">FINANCIALS</div>' +
            '<table width="100%" cellpadding="0" cellspacing="0">' +
            kv('Order Cost', '₹' + computedOrderCost.setScale(2), '') +
            taxRow + totalDueRow +
            kv('Paid to Mfr', '₹' + paid.setScale(2), '#16a34a') +
            kvLast('Still Owed', '₹' + stillOwed.setScale(2),
                stillOwed > 0 ? '#dc2626' : '#16a34a') +
            '</table></td></tr></table>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#eff6ff;border-radius:10px;margin-bottom:16px;">' +
            '<tr><td style="padding:18px 20px;">' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;' +
            'color:#3b82f6;margin-bottom:10px;">ACTION REQUIRED</div>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 6px;">✓ &nbsp;Confirm order with supplier ' + p.Supplier__r.Name + '</p>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 6px;">₹ &nbsp;Arrange payment as per agreed terms.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0;">→ &nbsp;Update delivery status once dispatched.</p>' +
            '</td></tr></table>';

        return wrap(
            '#0f172a', '#f5a623',
            'NEW ORDER', '#1e293b', '#60a5fa',
            'Purchase Order Placed',
            p.Name + ' · ' + p.Supplier__r.Name,
            body, '#f8fafc', '#94a3b8'
        );
    }

    // ── Email 2: Status Changed ─────────────────────────────────────────────
    private static String buildStatusChangedEmail(Purchase__c p) {
        Decimal orderCost = p.Total_Order_Cost__c != null ? p.Total_Order_Cost__c : 0;
        Decimal tax       = p.Tax_Amount__c != null ? p.Tax_Amount__c : 0;
        Decimal paid      = p.Total_Paid__c != null ? p.Total_Paid__c : 0;
        Decimal totalDue  = orderCost + tax;
        Decimal stillOwed = Math.max(0, totalDue - paid);

        String taxRow = tax > 0
            ? kv('+ Tax Paid',
                '<span style="color:#d97706;">₹' + tax.setScale(2) + '</span>', '')
            : '';
        String totalDueRow = tax > 0
            ? kv('Total Due to Mfr', '₹' + totalDue.setScale(2), '#111') : '';

        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A purchase order status has been updated.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fff7ed;border-radius:10px;margin-bottom:16px;">' +
            '<tr><td style="padding:16px 20px;">' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;' +
            'color:#ea580c;margin-bottom:4px;">CURRENT STATUS</div>' +
            '<div style="font-size:22px;font-weight:800;color:#111;">' +
            p.Delivery_Status__c + '</div>' +
            '</td></tr></table>' +

            card('Order Summary',
                kv('Order Number', p.Name, '') +
                kv('Supplier', p.Supplier__r.Name, '') +
                kv('Delivery Date',
                    p.Delivery_Date__c != null
                    ? p.Delivery_Date__c.format() : 'Pending', '') +
                kv('Order Cost', '₹' + orderCost.setScale(2), '') +
                taxRow + totalDueRow +
                kv('Paid to Mfr', '₹' + paid.setScale(2), '#16a34a') +
                kv('Still Owed', '₹' + stillOwed.setScale(2),
                    stillOwed > 0 ? '#dc2626' : '#16a34a') +
                kvLast('Payment Status', p.Manufacturer_Payment_Status__c, '')
            );

        return wrap(
            '#451a03', '#fb923c',
            'STATUS UPDATE', '#7c2d12', '#fdba74',
            'Order Status Changed',
            p.Name + ' is now ' + p.Delivery_Status__c,
            body, '#f8fafc', '#94a3b8'
        );
    }

    // ── Email 3: Goods Received ─────────────────────────────────────────────
    private static String buildGoodsReceivedEmail(Purchase__c p) {
        Decimal orderCost = p.Total_Order_Cost__c != null ? p.Total_Order_Cost__c : 0;
        Decimal tax       = p.Tax_Amount__c != null ? p.Tax_Amount__c : 0;
        Decimal paid      = p.Total_Paid__c != null ? p.Total_Paid__c : 0;
        Decimal totalDue  = orderCost + tax;
        Decimal stillOwed = Math.max(0, totalDue - paid);

        // FIX: Use actual date — NOT 'Today' string
        String receivedOn = p.Delivery_Date__c != null
            ? p.Delivery_Date__c.format()
            : Date.today().format();

        String taxRow = tax > 0
            ? kv('+ Tax Paid',
                '<span style="color:#d97706;">₹' + tax.setScale(2) + '</span>', '')
            : '';
        String totalDueRow = tax > 0
            ? kv('Total Due to Mfr', '₹' + totalDue.setScale(2), '#111') : '';

        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">Your order has arrived. Please verify ' +
            'the stock <strong>immediately</strong> before storing.</p>' +

            // Order value + received date box
            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f0fdf4;border-radius:10px;margin-bottom:16px;">' +
            '<tr><td style="padding:18px 22px;">' +
            '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
            '<td>' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;color:#16a34a;">ORDER VALUE</div>' +
            '<div style="font-size:26px;font-weight:800;color:#111;margin-top:2px;">₹' +
            orderCost.setScale(2) + '</div>' +
            (tax > 0 ? '<div style="font-size:11px;color:#d97706;margin-top:4px;">+ Tax ₹' + tax.setScale(2) + ' = Total ₹' + totalDue.setScale(2) + '</div>' : '') +
            '</td>' +
            '<td align="right">' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;color:#16a34a;">RECEIVED ON</div>' +
            '<div style="font-size:14px;font-weight:700;color:#111;margin-top:2px;">' +
            receivedOn + '</div>' +
            '</td>' +
            '</tr></table>' +
            '</td></tr></table>' +

            // Verification checklist
            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fefce8;border-radius:10px;border-left:4px solid #eab308;margin-bottom:16px;">' +
            '<tr><td style="padding:18px 20px;">' +
            '<div style="font-size:12px;font-weight:700;color:#854d0e;margin-bottom:12px;">⚠️ VERIFICATION CHECKLIST</div>' +
            '<p style="font-size:12px;color:#444;margin:0 0 8px;line-height:1.6;"><strong style="background:#fef9c3;color:#854d0e;padding:1px 6px;border-radius:4px;">1</strong>&nbsp;&nbsp;Check brand name on every box matches order.</p>' +
            '<p style="font-size:12px;color:#444;margin:0 0 8px;line-height:1.6;"><strong style="background:#fef9c3;color:#854d0e;padding:1px 6px;border-radius:4px;">2</strong>&nbsp;&nbsp;Count packets: <strong>100g → 10 packets = 1 KG</strong> · <strong>250g → 4 packets = 1 KG</strong> · Loose → weigh on scale.</p>' +
            '<p style="font-size:12px;color:#444;margin:0 0 8px;line-height:1.6;"><strong style="background:#fef9c3;color:#854d0e;padding:1px 6px;border-radius:4px;">3</strong>&nbsp;&nbsp;Check for damaged or missing packets.</p>' +
            '<p style="font-size:12px;color:#444;margin:0 0 8px;line-height:1.6;"><strong style="background:#fef9c3;color:#854d0e;padding:1px 6px;border-radius:4px;">4</strong>&nbsp;&nbsp;If correct → update Shrinkage in Salesforce.</p>' +
            '<p style="font-size:12px;color:#444;margin:0;line-height:1.6;"><strong style="background:#fef9c3;color:#854d0e;padding:1px 6px;border-radius:4px;">5</strong>&nbsp;&nbsp;If mismatch → contact ' + p.Supplier__r.Name + ' immediately. Do NOT update inventory.</p>' +
            '</td></tr></table>' +

            card('Payment Status',
                kv('Order Cost', '₹' + orderCost.setScale(2), '') +
                taxRow + totalDueRow +
                kv('Paid to Mfr', '₹' + paid.setScale(2), '#16a34a') +
                kv('Still Outstanding', '₹' + stillOwed.setScale(2),
                    stillOwed > 0 ? '#dc2626' : '#16a34a') +
                kvLast('Payment Status', p.Manufacturer_Payment_Status__c, '')
            );

        return wrap(
            '#052e16', '#4ade80',
            'GOODS RECEIVED', '#14532d', '#86efac',
            'Stock Arrived — Verify Now',
            p.Name + ' · ' + p.Supplier__r.Name,
            body, '#f0fdf4', '#86efac'
        );
    }

    // ── Email 4: Sale Delivered ─────────────────────────────────────────────
    private static String buildSaleDeliveredEmail(Sale__c s) {
        Decimal bal = s.Balance_Due__c != null ? s.Balance_Due__c : 0;
        Decimal rev = s.Total_Revenue__c != null ? s.Total_Revenue__c : 0;
        Decimal col = s.Total_Collected__c != null ? s.Total_Collected__c : 0;
        Decimal profit = s.Total_Profit__c != null ? s.Total_Profit__c : 0;

        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">An order has been delivered. ' +
            'Please collect payment from the client.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#faf5ff;border-radius:10px;margin-bottom:16px;">' +
            '<tr><td style="padding:18px 22px;">' +
            '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
            '<td><div style="font-size:10px;font-weight:700;text-transform:uppercase;color:#7c3aed;">BALANCE DUE</div>' +
            '<div style="font-size:28px;font-weight:800;color:#111;margin-top:2px;">₹' +
            bal.setScale(2) + '</div></td>' +
            '<td align="right"><div style="font-size:10px;font-weight:700;text-transform:uppercase;color:#7c3aed;">STATUS</div>' +
            '<div style="margin-top:6px;"><span style="background:#f3e8ff;color:#7c3aed;font-size:11px;font-weight:700;padding:4px 10px;border-radius:20px;">' +
            s.Payment_Status__c + '</span></div></td>' +
            '</tr></table></td></tr></table>' +

            card('Sale Details',
                kv('Sale Number', s.Name, '') +
                kv('Client', s.Client__r.Name, '') +
                kv('Sale Date',
                    s.Sale_Date__c != null ? s.Sale_Date__c.format() : '—', '') +
                kv('Handled By',
                    s.Regional_Manager__c != null ? s.Regional_Manager__c : '—', '') +
                kv('Total Revenue', '₹' + rev.setScale(2), '') +
                kv('Collected So Far', '₹' + col.setScale(2), '#16a34a') +
                kv('Balance Due', '₹' + bal.setScale(2), '#dc2626') +
                kvLast('Profit', '₹' + profit.setScale(2), '')
            ) +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#faf5ff;border-radius:10px;">' +
            '<tr><td style="padding:18px 20px;">' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;color:#7c3aed;margin-bottom:10px;">COLLECT PAYMENT NOW</div>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 6px;">✓ &nbsp;Confirm delivery with ' + s.Client__r.Name + '.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 6px;">₹ &nbsp;Collect ₹' + bal.setScale(2) + ' outstanding.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0;">📱 &nbsp;Log payment in Salesforce immediately.</p>' +
            '</td></tr></table>';

        return wrap(
            '#1e1b4b', '#a78bfa',
            'DELIVERED', '#312e81', '#c4b5fd',
            'Order Delivered',
            s.Name + ' · ' + s.Client__r.Name,
            body, '#faf5ff', '#c4b5fd'
        );
    }

    // ── Email 5: Payment Received ───────────────────────────────────────────
    private static String buildPaymentReceivedEmail(
        Client_Payment__c p, Sale__c s
    ) {
        Decimal amt  = p.Amount__c != null ? p.Amount__c : 0;
        Decimal rev  = s.Total_Revenue__c != null ? s.Total_Revenue__c : 0;
        Decimal col  = s.Total_Collected__c != null ? s.Total_Collected__c : 0;
        Decimal bal  = s.Balance_Due__c != null ? s.Balance_Due__c : 0;

        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A client payment has been received.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f0fdf4;border-radius:10px;margin-bottom:16px;">' +
            '<tr><td style="padding:22px;text-align:center;">' +
            '<div style="font-size:11px;color:#16a34a;font-weight:700;' +
            'text-transform:uppercase;letter-spacing:.1em;margin-bottom:6px;">AMOUNT RECEIVED</div>' +
            '<div style="font-size:36px;font-weight:900;color:#111;">₹' +
            amt.setScale(2) + '</div>' +
            '<div style="margin-top:10px;">' +
            '<span style="background:#dcfce7;color:#16a34a;font-size:11px;font-weight:700;padding:3px 10px;border-radius:20px;margin-right:6px;">' +
            (p.Mode_of_Payment__c != null ? p.Mode_of_Payment__c : '') + '</span>' +
            '<span style="background:#dcfce7;color:#16a34a;font-size:11px;font-weight:700;padding:3px 10px;border-radius:20px;">by ' +
            (p.Accepted_By__c != null ? p.Accepted_By__c : '') + '</span>' +
            '</div></td></tr></table>' +

            card('Payment Details',
                kv('Sale Number', s.Name, '') +
                kv('Client', s.Client__r.Name, '') +
                kv('Payment Date',
                    p.Payment_Date__c != null ? p.Payment_Date__c.format() : '—', '') +
                kvLast('Reference',
                    p.Reference__c != null ? p.Reference__c : '—', '')
            ) +

            card('Outstanding Balance',
                kv('Total Sale Value', '₹' + rev.setScale(2), '') +
                kv('Total Collected', '₹' + col.setScale(2), '#16a34a') +
                kv('Balance Still Due', '₹' + bal.setScale(2),
                    bal > 0 ? '#dc2626' : '#16a34a') +
                kvLast('Payment Status', s.Payment_Status__c, '')
            );

        return wrap(
            '#052e16', '#34d399',
            'PAYMENT IN ✓', '#14532d', '#6ee7b7',
            'Payment Received',
            s.Client__r.Name + ' · ' +
            (p.Payment_Date__c != null ? p.Payment_Date__c.format() : ''),
            body, '#f0fdf4', '#86efac'
        );
    }

    // ── Email 6: Weekly Pending ─────────────────────────────────────────────
    private static String buildWeeklyPendingEmail(
        String rows, Integer count, Decimal total
    ) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">Here is your weekly payment collection summary. ' +
            'These clients have outstanding balances.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fdf4ff;border-radius:10px;margin-bottom:16px;overflow:hidden;">' +
            '<tr>' + th('Client') + th('Sale #') + th('Sale Date') +
            th('Manager') + th('Balance Due') + '</tr>' +
            rows +
            '<tr><td colspan="4" style="padding:10px 12px;font-size:12px;' +
            'font-weight:700;color:#374151;border-top:2px solid #e9d5ff;">Total Outstanding</td>' +
            '<td style="padding:10px 12px;font-size:14px;font-weight:900;' +
            'color:#dc2626;text-align:right;border-top:2px solid #e9d5ff;">₹' +
            total.setScale(2) + '</td></tr>' +
            '</table>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fdf4ff;border-radius:10px;">' +
            '<tr><td style="padding:18px 20px;">' +
            '<div style="font-size:10px;font-weight:700;text-transform:uppercase;color:#7e22ce;margin-bottom:10px;">THIS WEEK\'S ACTION PLAN</div>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 8px;"><strong style="background:#f3e8ff;color:#7e22ce;padding:1px 6px;border-radius:4px;">1</strong>&nbsp;&nbsp;Prioritise clients with highest outstanding amounts first.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 8px;"><strong style="background:#f3e8ff;color:#7e22ce;padding:1px 6px;border-radius:4px;">2</strong>&nbsp;&nbsp;Call or visit those clients in person this week.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0;"><strong style="background:#f3e8ff;color:#7e22ce;padding:1px 6px;border-radius:4px;">3</strong>&nbsp;&nbsp;Log every payment in Salesforce immediately — updates balances in real time.</p>' +
            '</td></tr></table>';

        return wrap(
            '#1f1235', '#f472b6',
            'WEEKLY REPORT', '#2d1b4e', '#f9a8d4',
            'Pending Payments — ' + count + ' Clients',
            'Week of ' + Date.today().format() + ' · Action Required',
            body, '#fdf4ff', '#d8b4fe'
        );
    }
}