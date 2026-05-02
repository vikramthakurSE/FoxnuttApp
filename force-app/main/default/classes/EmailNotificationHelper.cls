public class EmailNotificationHelper {

    // ── Get all active System Admin emails ──────────────────────────
    private static List<String> getAdminEmails() {
        List<String> emails = new List<String>{'vikramthakur381@gmail.com','rohanagarwalprp@gmail.com'};
        
        return emails;
    }

    // ── Core send method ─────────────────────────────────────────────
    private static void sendEmail(
        String subject,
        String htmlBody,
        List<String> toAddresses
    ) {
        system.debug(toAddresses);
        if (toAddresses == null || toAddresses.isEmpty()) return;

        Messaging.SingleEmailMessage mail =
            new Messaging.SingleEmailMessage();
        mail.setToAddresses(toAddresses);
        mail.setSubject(subject);
        mail.setHtmlBody(htmlBody);
        mail.setSaveAsActivity(false);

        try {
            Messaging.sendEmail(
                new List<Messaging.SingleEmailMessage>{ mail }
            );
        } catch (Exception e) {
            System.debug('Email send failed: ' + e.getMessage());
        }
    }

    // ════════════════════════════════════════════════════════════════
    // 1. NEW PURCHASE LINE ITEM — fires from PurchaseLineItemTrigger
    // ════════════════════════════════════════════════════════════════
    public static void sendNewPurchaseAlert(
        List<Purchase_Line_Item__c> lineItems
    ) {
        if (lineItems.isEmpty()) return;

        // Group line items by parent Purchase
        Set<Id> purchaseIds = new Set<Id>();
        for (Purchase_Line_Item__c li : lineItems) {
            if (li.Purchase__c != null) purchaseIds.add(li.Purchase__c);
        }

        Map<Id, Purchase__c> purchases = new Map<Id, Purchase__c>([
            SELECT Id, Name, Unique_Order_Code__c,
                   Supplier__r.Name, Order_Date__c,
                   Quarter__c, Delivery_Status__c,
                   Total_Order_Cost__c, Amount_Outstanding__c,
                   Manufacturer_Payment_Status__c
            FROM Purchase__c
            WHERE Id IN :purchaseIds
        ]);

        // Group line items under each purchase
        Map<Id, List<Purchase_Line_Item__c>> liMap =
            new Map<Id, List<Purchase_Line_Item__c>>();
        for (Purchase_Line_Item__c li : lineItems) {
            if (!liMap.containsKey(li.Purchase__c)) {
                liMap.put(li.Purchase__c,
                    new List<Purchase_Line_Item__c>());
            }
            liMap.get(li.Purchase__c).add(li);
        }

        List<String> admins = getAdminEmails();

        for (Id purId : liMap.keySet()) {
            Purchase__c p = purchases.get(purId);
            if (p == null) continue;

            List<Purchase_Line_Item__c> items = liMap.get(purId);

            // Build line items rows
            String itemRows = '';
            for (Purchase_Line_Item__c li : items) {
                Decimal total = (li.Quantity__c != null &&
                    li.Landing_Cost_Per_Kg__c != null)
                    ? li.Quantity__c * li.Landing_Cost_Per_Kg__c : 0;
                itemRows +=
                    '<tr>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;">' +
                    li.Brand__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                    'text-align:center;">' +
                    li.Packet_Type__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                    'text-align:center;">' +
                    li.Quantity__c + ' KG</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                    'text-align:right;">₹' +
                    li.Landing_Cost_Per_Kg__c + '/kg</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;font-weight:600;' +
                    'color:#111;text-align:right;">₹' +
                    total.setScale(2) + '</td>' +
                    '</tr>';
            }

            String html = buildPurchaseAlertEmail(p, itemRows);
            String subject = 'New Purchase Order — ' + p.Name +
                ' | ' + p.Supplier__r.Name;

            sendEmail(subject, html, admins);
        }
    }

    // ════════════════════════════════════════════════════════════════
    // 2. PURCHASE STATUS CHANGED — fires from PurchaseTrigger
    // ════════════════════════════════════════════════════════════════
    public static void sendPurchaseStatusChanged(
        List<Purchase__c> purchases
    ) {
        List<String> admins = getAdminEmails();
        for (Purchase__c p : purchases) {
            Boolean isReceived =
                p.Delivery_Status__c == 'Received';
            String subject = isReceived
                ? '✅ GOODS RECEIVED — ' + p.Name +
                  ' | Verify Stock Now'
                : 'Purchase Status Updated — ' + p.Name +
                  ' is now ' + p.Delivery_Status__c;
            String html = isReceived
                ? buildGoodsReceivedEmail(p)
                : buildStatusChangedEmail(p);
            sendEmail(subject, html, admins);
        }
    }

    // ════════════════════════════════════════════════════════════════
    // 3. NEW SALE LINE ITEM — fires from SaleLineItemTrigger
    // ════════════════════════════════════════════════════════════════
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
                   Total_Profit__c, Balance_Due__c,
                   Payment_Status__c, Client__r.Name
            FROM Sale__c
            WHERE Id IN :saleIds
        ]);

        Map<Id, List<Sale_Line_Item__c>> liMap =
            new Map<Id, List<Sale_Line_Item__c>>();
        for (Sale_Line_Item__c li : lineItems) {
            if (!liMap.containsKey(li.Sale__c)) {
                liMap.put(li.Sale__c,
                    new List<Sale_Line_Item__c>());
            }
            liMap.get(li.Sale__c).add(li);
        }

        List<String> admins = getAdminEmails();

        for (Id saleId : liMap.keySet()) {
            Sale__c s = sales.get(saleId);
            if (s == null) continue;

            List<Sale_Line_Item__c> items = liMap.get(saleId);

            String itemRows = '';
            for (Sale_Line_Item__c li : items) {
                Decimal lineAmt = (li.Quantity__c != null &&
                    li.Rate_Per_Kg__c != null)
                    ? li.Quantity__c * li.Rate_Per_Kg__c : 0;
                itemRows +=
                    '<tr>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;">' +
                    li.Brand__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                    'text-align:center;">' + li.Packet_Type__c + '</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                    'text-align:center;">' + li.Quantity__c + ' KG</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                    'text-align:right;">₹' +
                    li.Rate_Per_Kg__c + '/kg</td>' +
                    '<td style="padding:8px 12px;border-bottom:' +
                    '1px solid #f0f0f0;font-size:12px;font-weight:600;' +
                    'color:#111;text-align:right;">₹' +
                    lineAmt.setScale(2) + '</td>' +
                    '</tr>';
            }

            String html = buildSaleAlertEmail(s, itemRows);
            String subject = 'New Sale — ' + s.Name +
                ' | ' + s.Client__r.Name;
            sendEmail(subject, html, admins);
        }
    }

    // ════════════════════════════════════════════════════════════════
    // 4. SALE DELIVERED — fires from SaleTrigger
    // ════════════════════════════════════════════════════════════════
    public static void sendSaleDelivered(List<Sale__c> sales) {
        List<String> admins = getAdminEmails();
        for (Sale__c s : sales) {
            String subject = 'Delivered — ' + s.Name +
                ' | ' + s.Client__r.Name +
                ' | Balance: ₹' + s.Balance_Due__c;
            sendEmail(subject, buildSaleDeliveredEmail(s), admins);
        }
    }

    // ════════════════════════════════════════════════════════════════
    // 5. CLIENT PAYMENT RECEIVED — fires from ClientPaymentTrigger
    // ════════════════════════════════════════════════════════════════
    public static void sendPaymentReceived(List<Client_Payment__c> payments)
    {
        Set<Id> saleIds = new Set<Id>();
        for (Client_Payment__c p : payments) {
            if (p.Sale__c != null) saleIds.add(p.Sale__c);
        }
    
        Map<Id, Sale__c> sales = new Map<Id, Sale__c>([
            SELECT Id, Name, Total_Revenue__c,
                   Client__r.Name
            FROM Sale__c WHERE Id IN :saleIds
        ]);
    
        // Calculate collected by summing ALL payments directly
        Map<Id, Decimal> collectedMap = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Sale__c, SUM(Amount__c) total
            FROM Client_Payment__c
            WHERE Sale__c IN :saleIds
            GROUP BY Sale__c
        ]) {
            collectedMap.put(
                (Id) ar.get('Sale__c'),
                (Decimal) ar.get('total')
            );
        }
    
        List<String> admins = getAdminEmails();
    
        for (Client_Payment__c p : payments) {
            Sale__c s = sales.get(p.Sale__c);
            if (s == null) continue;
    
            Decimal revenue   = s.Total_Revenue__c != null
                                ? s.Total_Revenue__c : 0;
            Decimal collected = collectedMap.containsKey(s.Id)
                                ? collectedMap.get(s.Id) : 0;
            Decimal balance   = Math.max(0, revenue - collected);
    
            // Build email with freshly calculated values
            String subject = '✅ Payment Received — ₹' +
                p.Amount__c + ' from ' + s.Client__r.Name;
            sendEmail(subject,
                buildPaymentReceivedEmailFresh(
                    p, s, collected, balance
                ), admins);
        }
    }
    
    private static String buildPaymentReceivedEmailFresh(
    Client_Payment__c p,
    Sale__c s,
    Decimal collected,
    Decimal balance
    ) {
        String payStatus = balance <= 0 ? 'Fully Paid' : 'Partially Paid';
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A client payment has been received.</p>' +
    
            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f0fdf4;border-radius:10px;' +
            'margin-bottom:16px;"><tr>' +
            '<td style="padding:22px;text-align:center;">' +
            '<div style="font-size:11px;color:#16a34a;font-weight:700;' +
            'text-transform:uppercase;letter-spacing:.1em;' +
            'margin-bottom:6px;">AMOUNT RECEIVED</div>' +
            '<div style="font-size:36px;font-weight:900;color:#111;">₹' +
            (p.Amount__c != null ? p.Amount__c.setScale(2) : 0.00) +
            '</div>' +
            '<div style="margin-top:10px;">' +
            '<span style="background:#dcfce7;color:#16a34a;font-size:11px;' +
            'font-weight:700;padding:3px 10px;border-radius:20px;' +
            'margin-right:6px;">' +
            (p.Mode_of_Payment__c != null ? p.Mode_of_Payment__c : '') +
            '</span>' +
            '<span style="background:#dcfce7;color:#16a34a;font-size:11px;' +
            'font-weight:700;padding:3px 10px;border-radius:20px;">by ' +
            (p.Accepted_By__c != null ? p.Accepted_By__c : '') +
            '</span></div>' +
            '</td></tr></table>' +
    
            card('Payment Details',
                kv('Sale Number', s.Name, '') +
                kv('Client', s.Client__r.Name, '') +
                kv('Payment Date',
                    p.Payment_Date__c != null
                    ? p.Payment_Date__c.format() : '—', '') +
                kv('Reference',
                    p.Reference__c != null ? p.Reference__c : '—', '')
            ) +
    
            card('Outstanding Balance',
                kv('Total Sale Value',
                    '₹' + (s.Total_Revenue__c != null
                    ? s.Total_Revenue__c.setScale(2) : 0), '') +
                kv('Total Collected',
                    '₹' + collected.setScale(2), '#16a34a') +
                kv('Balance Still Due',
                    '₹' + balance.setScale(2),
                    balance > 0 ? '#dc2626' : '#16a34a') +
                kv('Payment Status', payStatus, '')
            );
    
        return emailWrap(
            '#052e16', '#34d399',
            'PAYMENT IN ✓', '#14532d', '#6ee7b7',
            'Payment Received',
            s.Client__r.Name + ' · ' +
            (p.Payment_Date__c != null ? p.Payment_Date__c.format() : ''),
            body, '#f0fdf4', '#86efac'
        );
    }

    // ════════════════════════════════════════════════════════════════
    // 6. WEEKLY PENDING — called from Schedulable class
    // ════════════════════════════════════════════════════════════════
    public static void sendWeeklyPendingPayments() {
        List<Sale__c> pending = [
            SELECT Id, Name, Sale_Date__c,
                   Client__r.Name, Balance_Due__c,
                   Payment_Status__c, Regional_Manager__c
            FROM Sale__c
            WHERE Payment_Status__c != 'Fully Paid'
            AND Order_Status__c = 'Delivered'
            AND Balance_Due__c > 0
            ORDER BY Balance_Due__c DESC
            LIMIT 50
        ];

        if (pending.isEmpty()) return;

        Decimal totalPending = 0;
        String rows = '';
        for (Sale__c s : pending) {
            totalPending += s.Balance_Due__c != null
                ? s.Balance_Due__c : 0;
            rows +=
                '<tr>' +
                '<td style="padding:8px 12px;border-bottom:' +
                '1px solid #f0f0f0;font-size:12px;color:#374151;">' +
                s.Client__r.Name + '</td>' +
                '<td style="padding:8px 12px;border-bottom:' +
                '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                'text-align:center;">' + s.Name + '</td>' +
                '<td style="padding:8px 12px;border-bottom:' +
                '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                'text-align:center;">' +
                s.Sale_Date__c.format() + '</td>' +
                '<td style="padding:8px 12px;border-bottom:' +
                '1px solid #f0f0f0;font-size:12px;color:#374151;' +
                'text-align:center;">' +
                s.Regional_Manager__c + '</td>' +
                '<td style="padding:8px 12px;border-bottom:' +
                '1px solid #f0f0f0;font-size:12px;font-weight:700;' +
                'color:#dc2626;text-align:right;">₹' +
                s.Balance_Due__c.setScale(2) + '</td>' +
                '</tr>';
        }

        List<String> admins = getAdminEmails();
        String subject = '📋 Weekly Pending Payments — ' +
            pending.size() + ' clients | Total: ₹' +
            totalPending.setScale(2);
        sendEmail(subject,
            buildWeeklyPendingEmail(rows,
                pending.size(), totalPending), admins);
    }

    // ════════════════════════════════════════════════════════════════
    // EMAIL BODY BUILDERS
    // ════════════════════════════════════════════════════════════════

    private static String emailWrap(
        String headerBg, String headerColor,
        String badgeText, String badgeBg, String badgeColor,
        String titleText, String subtitleText,
        String bodyContent, String footerBg, String footerColor
    ) {
        return
        '<!DOCTYPE html><html><body style="margin:0;padding:0;' +
        'background:#f5f5f5;font-family:Helvetica Neue,Arial,' +
        'sans-serif;">' +
        '<table width="100%" cellpadding="0" cellspacing="0">' +
        '<tr><td align="center" style="padding:24px 16px;">' +
        '<table width="580" cellpadding="0" cellspacing="0" ' +
        'style="background:#fff;border-radius:12px;overflow:hidden;' +
        'box-shadow:0 4px 24px rgba(0,0,0,.08);max-width:580px;">' +

        // Header
        '<tr><td style="background:' + headerBg + ';' +
        'padding:24px 32px;">' +
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
        '<td style="font-size:13px;font-weight:700;color:' +
        headerColor + ';letter-spacing:.04em;text-transform:uppercase;">' +
        '🌾 Makhana Co.</td>' +
        '<td align="right"><span style="background:' + badgeBg +
        ';color:' + badgeColor +
        ';font-size:10px;font-weight:600;padding:4px 10px;' +
        'border-radius:20px;">' + badgeText + '</span></td>' +
        '</tr></table></td></tr>' +

        // Hero
        '<tr><td style="background:' + headerBg +
        ';padding:0 32px 28px;">' +
        '<div style="font-size:22px;font-weight:700;color:#fff;' +
        'line-height:1.3;margin-bottom:4px;">' + titleText + '</div>' +
        '<div style="font-size:12px;color:' + subtitleText +
        ';">' + subtitleText + '</div></td></tr>' +

        // Divider
        '<tr><td style="height:1px;background:#e5e7eb;' +
        'font-size:0;line-height:0;">&nbsp;</td></tr>' +

        // Body
        '<tr><td style="padding:28px 32px;">' +
        bodyContent + '</td></tr>' +

        // Divider
        '<tr><td style="height:1px;background:#f3f4f6;' +
        'font-size:0;line-height:0;">&nbsp;</td></tr>' +

        // Footer
        '<tr><td style="background:' + footerBg +
        ';padding:16px 32px 20px;">' +
        '<p style="font-size:11px;color:' + footerColor +
        ';margin:0;line-height:1.6;">' +
        'Automated notification · ' +
        '<strong style="text-transform:uppercase;' +
        'letter-spacing:.04em;">Makhana Business App</strong>' +
        '</p></td></tr>' +

        '</table></td></tr></table></body></html>';
    }

    private static String card(String title, String rows) {
        return
        '<table width="100%" cellpadding="0" cellspacing="0" ' +
        'style="background:#f9fafb;border-radius:10px;' +
        'margin-bottom:16px;">' +
        '<tr><td style="padding:18px 20px;">' +
        '<div style="font-size:10px;font-weight:700;' +
        'text-transform:uppercase;letter-spacing:.08em;' +
        'color:#9ca3af;margin-bottom:12px;">' + title + '</div>' +
        '<table width="100%" cellpadding="0" cellspacing="0">' +
        rows + '</table>' +
        '</td></tr></table>';
    }

    private static String kv(
        String label, String value, String valColor
    ) {
        return
        '<tr>' +
        '<td style="padding:6px 0;border-bottom:1px solid #f0f0f0;' +
        'font-size:12px;color:#9ca3af;">' + label + '</td>' +
        '<td align="right" style="padding:6px 0;border-bottom:' +
        '1px solid #f0f0f0;font-size:12px;font-weight:600;color:' +
        (String.isBlank(valColor) ? '#111' : valColor) +
        ';">' + value + '</td>' +
        '</tr>';
    }

    private static String lineItemTable(
        String headers, String rows
    ) {
        return
        '<table width="100%" cellpadding="0" cellspacing="0" ' +
        'style="background:#f9fafb;border-radius:10px;' +
        'margin-bottom:16px;overflow:hidden;">' +
        '<tr>' + headers + '</tr>' +
        rows +
        '</table>';
    }

    private static String th(String label) {
        return
        '<th style="padding:10px 12px;background:#f3f4f6;' +
        'font-size:10px;font-weight:700;text-transform:uppercase;' +
        'letter-spacing:.06em;color:#6b7280;text-align:left;' +
        'border-bottom:1px solid #e5e7eb;">' + label + '</th>';
    }

    private static String amountBox(
        String label, String amount,
        String bg, String labelColor
    ) {
        return
        '<table width="100%" cellpadding="0" cellspacing="0" ' +
        'style="background:' + bg +
        ';border-radius:10px;margin-bottom:16px;">' +
        '<tr><td style="padding:18px 22px;">' +
        '<div style="font-size:10px;font-weight:700;' +
        'text-transform:uppercase;letter-spacing:.08em;color:' +
        labelColor + ';margin-bottom:4px;">' + label + '</div>' +
        '<div style="font-size:28px;font-weight:800;color:#111;">' +
        amount + '</div>' +
        '</td></tr></table>';
    }

    private static String actionBox(
        String bg, String titleColor,
        String title, List<String> actions
    ) {
        String items = '';
        for (String a : actions) {
            items +=
                '<p style="font-size:12px;color:#374151;' +
                'margin:0 0 8px;line-height:1.6;">' + a + '</p>';
        }
        return
        '<table width="100%" cellpadding="0" cellspacing="0" ' +
        'style="background:' + bg +
        ';border-radius:10px;margin-bottom:16px;">' +
        '<tr><td style="padding:18px 20px;">' +
        '<div style="font-size:10px;font-weight:700;' +
        'text-transform:uppercase;letter-spacing:.08em;color:' +
        titleColor + ';margin-bottom:12px;">' + title + '</div>' +
        items + '</td></tr></table>';
    }

    // ── Email 1: New Purchase ────────────────────────────────────────
    private static String buildPurchaseAlertEmail(
        Purchase__c p, String itemRows
    ) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A new purchase order has been placed. ' +
            'Line items are shown below.</p>' +

            card('Order Details',
                kv('Order Number', p.Name, '') +
                kv('Order Code',
                    p.Unique_Order_Code__c != null
                    ? p.Unique_Order_Code__c : '—', '') +
                kv('Supplier', p.Supplier__r.Name, '') +
                kv('Order Date',
                    p.Order_Date__c != null
                    ? p.Order_Date__c.format() : '—', '') +
                kv('Quarter',
                    p.Quarter__c != null ? p.Quarter__c : '—', '') +
                kv('Status', p.Delivery_Status__c, '#d97706')
            ) +

            lineItemTable(
                th('Brand') + th('Type') +
                th('Qty') + th('Rate') + th('Total'),
                itemRows
            ) +

            amountBox('Total Order Cost',
                        '₹' + String.valueOf(
                            (p.Total_Order_Cost__c != null
                                ? p.Total_Order_Cost__c.setScale(2)
                                : 0)
                        ),
                        '#f0fdf4', '#16a34a') +

            actionBox('#eff6ff', '#3b82f6', 'Action Required',
                new List<String>{
                    '✓ &nbsp;Confirm order with supplier ' +
                    p.Supplier__r.Name,
                    '₹ &nbsp;Arrange payment as per agreed terms.',
                    '→ &nbsp;Update delivery status once dispatched.'
                });

        return emailWrap(
            '#0f172a', '#f5a623',
            'NEW ORDER', '#1e293b', '#60a5fa',
            'Purchase Order Placed',
            p.Name + ' · ' + p.Supplier__r.Name,
            body, '#f8fafc', '#94a3b8'
        );
    }

    // ── Email 2: Status Changed ──────────────────────────────────────
    private static String buildStatusChangedEmail(Purchase__c p) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A purchase order status has been ' +
            'updated.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fff7ed;border-radius:10px;' +
            'margin-bottom:16px;"><tr><td style="padding:16px 20px;">' +
            '<div style="font-size:10px;font-weight:700;' +
            'text-transform:uppercase;color:#ea580c;margin-bottom:4px;">' +
            'CURRENT STATUS</div>' +
            '<div style="font-size:22px;font-weight:800;color:#111;">' +
            p.Delivery_Status__c + '</div>' +
            '</td></tr></table>' +

            card('Order Summary',
                kv('Order Number', p.Name, '') +
                kv('Supplier', p.Supplier__r.Name, '') +
                kv('Delivery Date',
                    p.Delivery_Date__c != null
                    ? p.Delivery_Date__c.format() : 'Pending', '') +
                kv('Total Cost', '₹' +
                        String.valueOf(
                            (p.Total_Order_Cost__c != null
                                ? p.Total_Order_Cost__c.setScale(2)
                                : 0)
                        ), '') +

                kv('Amount Paid', '₹' +
                    String.valueOf(
                        (p.Total_Paid__c != null
                            ? p.Total_Paid__c.setScale(2)
                            : 0)
                    ), '#16a34a') +
                
                kv('Outstanding', '₹' +
                    String.valueOf(
                        (p.Amount_Outstanding__c != null
                            ? p.Amount_Outstanding__c.setScale(2)
                            : 0)
                    ),
                    '#dc2626') +
                
                kv('Payment Status',
                    p.Manufacturer_Payment_Status__c, '')
                            );
                
                        return emailWrap(
                            '#451a03', '#fb923c',
                            'STATUS UPDATE', '#7c2d12', '#fdba74',
                            'Order Status Changed',
                            p.Name + ' is now ' + p.Delivery_Status__c,
                            body, '#f8fafc', '#94a3b8'
                        );
    }

    // ── Email 3: Goods Received ──────────────────────────────────────
    private static String buildGoodsReceivedEmail(Purchase__c p) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">Your order has arrived. Please verify ' +
            'the stock <strong>immediately</strong> before storing.' +
            '</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f0fdf4;border-radius:10px;' +
            'margin-bottom:16px;"><tr><td style="padding:18px 22px;">' +
            '<table width="100%" cellpadding="0" cellspacing="0">' +
            '<tr>' +
            '<td><div style="font-size:10px;font-weight:700;' +
            'text-transform:uppercase;color:#16a34a;">ORDER VALUE</div>' +
            '<div style="font-size:26px;font-weight:800;color:#111;' +
            'margin-top:2px;">₹' +
            (p.Total_Order_Cost__c != null
                ? p.Total_Order_Cost__c.setScale(2) : 0) +
            '</div></td>' +
            '<td align="right">' +
            '<div style="font-size:10px;font-weight:700;' +
            'text-transform:uppercase;color:#16a34a;">RECEIVED ON</div>' +
            '<div style="font-size:14px;font-weight:700;color:#111;' +
            'margin-top:2px;">' +
            (p.Delivery_Date__c != null
                ? p.Delivery_Date__c.format() : 'Today') +
            '</div></td>' +
            '</tr></table>' +
            '</td></tr></table>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fefce8;border-radius:10px;' +
            'border-left:4px solid #eab308;margin-bottom:16px;">' +
            '<tr><td style="padding:18px 20px;">' +
            '<div style="font-size:12px;font-weight:700;color:#854d0e;' +
            'margin-bottom:12px;">⚠️ VERIFICATION CHECKLIST</div>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 8px;' +
            'line-height:1.6;"><strong style="background:#fef9c3;' +
            'color:#854d0e;padding:1px 6px;border-radius:4px;">1</strong>' +
            '&nbsp;&nbsp;Check brand name on every box matches order.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 8px;' +
            'line-height:1.6;"><strong style="background:#fef9c3;' +
            'color:#854d0e;padding:1px 6px;border-radius:4px;">2</strong>' +
            '&nbsp;&nbsp;Count packets: ' +
            '<strong>100g → 10 packets = 1 KG</strong> · ' +
            '<strong>250g → 4 packets = 1 KG</strong> · ' +
            'Loose → weigh on scale.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 8px;' +
            'line-height:1.6;"><strong style="background:#fef9c3;' +
            'color:#854d0e;padding:1px 6px;border-radius:4px;">3</strong>' +
            '&nbsp;&nbsp;Check for damaged or missing packets.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0 0 8px;' +
            'line-height:1.6;"><strong style="background:#fef9c3;' +
            'color:#854d0e;padding:1px 6px;border-radius:4px;">4</strong>' +
            '&nbsp;&nbsp;If correct → update Shrinkage in Salesforce.</p>' +
            '<p style="font-size:12px;color:#374151;margin:0;' +
            'line-height:1.6;"><strong style="background:#fef9c3;' +
            'color:#854d0e;padding:1px 6px;border-radius:4px;">5</strong>' +
            '&nbsp;&nbsp;If mismatch → contact ' + p.Supplier__r.Name +
            ' immediately. Do NOT update inventory.</p>' +
            '</td></tr></table>' +

            card('Payment Status',
                kv('Total Paid', '₹' +
                    (p.Total_Paid__c != null
                    ? p.Total_Paid__c.setScale(2) : 0), '#16a34a') +
                kv('Still Outstanding', '₹' +
                    (p.Amount_Outstanding__c != null
                    ? p.Amount_Outstanding__c.setScale(2) : 0),
                    '#dc2626') +
                kv('Payment Status',
                    p.Manufacturer_Payment_Status__c, '')
            );

        return emailWrap(
            '#052e16', '#4ade80',
            'GOODS RECEIVED', '#14532d', '#86efac',
            'Stock Arrived — Verify Now',
            p.Name + ' · ' + p.Supplier__r.Name,
            body, '#f0fdf4', '#86efac'
        );
    }

    // ── Email 4: New Sale ────────────────────────────────────────────
    private static String buildSaleAlertEmail(
        Sale__c s, String itemRows
    ) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A new sale has been recorded. ' +
            'Line items are listed below.</p>' +

            card('Sale Details',
                kv('Sale Number', s.Name, '') +
                kv('Client', s.Client__r.Name, '') +
                kv('Sale Date',
                    s.Sale_Date__c != null
                    ? s.Sale_Date__c.format() : '—', '') +
                kv('Handled By',
                    s.Regional_Manager__c != null
                    ? s.Regional_Manager__c : '—', '') +
                kv('Status', s.Order_Status__c, '#d97706')
            ) +

            lineItemTable(
                th('Brand') + th('Type') +
                th('Qty') + th('Rate') + th('Total'),
                itemRows
            ) +

            actionBox('#eff6ff', '#3b82f6', 'Next Steps',
                new List<String>{
                    '→ &nbsp;Confirm delivery with client.',
                    '₹ &nbsp;Collect payment once delivered.',
                    '📱 &nbsp;Log payment in Salesforce immediately.'
                });

        return emailWrap(
            '#1e1b4b', '#a78bfa',
            'NEW SALE', '#312e81', '#c4b5fd',
            'Sale Recorded',
            s.Name + ' · ' + s.Client__r.Name,
            body, '#faf5ff', '#c4b5fd'
        );
    }

    // ── Email 5: Sale Delivered ──────────────────────────────────────
    private static String buildSaleDeliveredEmail(Sale__c s) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">An order has been delivered. ' +
            'Please collect payment from the client.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#faf5ff;border-radius:10px;' +
            'margin-bottom:16px;"><tr><td style="padding:18px 22px;">' +
            '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
            '<td><div style="font-size:10px;font-weight:700;' +
            'text-transform:uppercase;color:#7c3aed;">BALANCE DUE</div>' +
            '<div style="font-size:28px;font-weight:800;color:#111;' +
            'margin-top:2px;">₹' +
            (s.Balance_Due__c != null
                ? s.Balance_Due__c.setScale(2) : 0) +
            '</div></td>' +
            '<td align="right"><div style="font-size:10px;font-weight:700;' +
            'text-transform:uppercase;color:#7c3aed;">STATUS</div>' +
            '<div style="margin-top:6px;">' +
            '<span style="background:#f3e8ff;color:#7c3aed;' +
            'font-size:11px;font-weight:700;padding:4px 10px;' +
            'border-radius:20px;">' + s.Payment_Status__c +
            '</span></div></td>' +
            '</tr></table></td></tr></table>' +

            card('Sale Details',
                kv('Sale Number', s.Name, '') +
                kv('Client', s.Client__r.Name, '') +
                kv('Sale Date',
                    s.Sale_Date__c != null
                    ? s.Sale_Date__c.format() : '—', '') +
                kv('Handled By',
                    s.Regional_Manager__c != null
                    ? s.Regional_Manager__c : '—', '') +
                kv('Total Revenue', '₹' +
                    (s.Total_Revenue__c != null
                    ? s.Total_Revenue__c.setScale(2) : 0), '') +
                kv('Collected So Far', '₹' +
                    (s.Total_Collected__c != null
                    ? s.Total_Collected__c.setScale(2) : 0),
                    '#16a34a') +
                kv('Balance Due', '₹' +
                    (s.Balance_Due__c != null
                    ? s.Balance_Due__c.setScale(2) : 0),
                    '#dc2626') +
                kv('Profit', '₹' +
                    (s.Total_Profit__c != null
                    ? s.Total_Profit__c.setScale(2) : 0), '')
            ) +

            actionBox('#faf5ff', '#7c3aed', 'Collect Payment Now',
                new List<String>{
                    '✓ &nbsp;Confirm delivery with ' +
                    s.Client__r.Name + '.',
                    '₹ &nbsp;Collect ₹' +
                    (s.Balance_Due__c != null
                        ? s.Balance_Due__c.setScale(2) : 0) +
                    ' outstanding.',
                    '📱 &nbsp;Log payment in Salesforce immediately.'
                });

        return emailWrap(
            '#1e1b4b', '#a78bfa',
            'DELIVERED', '#312e81', '#c4b5fd',
            'Order Delivered',
            s.Name + ' · ' + s.Client__r.Name,
            body, '#faf5ff', '#c4b5fd'
        );
    }

    // ── Email 6: Payment Received ────────────────────────────────────
    private static String buildPaymentReceivedEmail(
        Client_Payment__c p, Sale__c s
    ) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">A client payment has been received.' +
            '</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#f0fdf4;border-radius:10px;' +
            'margin-bottom:16px;"><tr>' +
            '<td style="padding:22px;text-align:center;">' +
            '<div style="font-size:11px;color:#16a34a;font-weight:700;' +
            'text-transform:uppercase;letter-spacing:.1em;' +
            'margin-bottom:6px;">AMOUNT RECEIVED</div>' +
            '<div style="font-size:36px;font-weight:900;color:#111;">₹' +
            (p.Amount__c != null
                ? p.Amount__c.setScale(2) : 0) +
            '</div>' +
            '<div style="margin-top:10px;">' +
            '<span style="background:#dcfce7;color:#16a34a;font-size:11px;' +
            'font-weight:700;padding:3px 10px;border-radius:20px;' +
            'margin-right:6px;">' +
            (p.Mode_of_Payment__c  != null ? p.Mode_of_Payment__c  : '') + '</span>' +
            '<span style="background:#dcfce7;color:#16a34a;font-size:11px;' +
            'font-weight:700;padding:3px 10px;border-radius:20px;">by ' +
            (p.Accepted_By__c != null ? p.Accepted_By__c : '') +
            '</span></div>' +
            '</td></tr></table>' +

            card('Payment Details',
                kv('Sale Number', s.Name, '') +
                kv('Client', s.Client__r.Name, '') +
                kv('Payment Date',
                    p.Payment_Date__c != null
                    ? p.Payment_Date__c.format() : '—', '') +
                kv('Reference',
                    p.Reference__c != null
                    ? p.Reference__c : '—', '')
            ) +

            card('Outstanding Balance',
                kv('Total Sale Value', '₹' +
                    (s.Total_Revenue__c != null
                    ? s.Total_Revenue__c.setScale(2) : 0), '') +
                kv('Total Collected', '₹' +
                    (s.Total_Collected__c != null
                    ? s.Total_Collected__c.setScale(2) : 0),
                    '#16a34a') +
                kv('Balance Still Due', '₹' +
                    (s.Balance_Due__c != null
                    ? s.Balance_Due__c.setScale(2) : 0),
                    '#dc2626') +
                kv('Payment Status', s.Payment_Status__c, '')
            );

        return emailWrap(
            '#052e16', '#34d399',
            'PAYMENT IN ✓', '#14532d', '#6ee7b7',
            'Payment Received',
            s.Client__r.Name + ' · ' +
            (p.Payment_Date__c != null
                ? p.Payment_Date__c.format() : ''),
            body, '#f0fdf4', '#86efac'
        );
    }

    // ── Email 7: Weekly Pending ──────────────────────────────────────
    private static String buildWeeklyPendingEmail(
        String rows, Integer count, Decimal total
    ) {
        String body =
            '<p style="font-size:14px;color:#374151;line-height:1.6;' +
            'margin:0 0 20px;">Here is your weekly payment collection ' +
            'summary. These clients have outstanding balances.</p>' +

            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#fdf4ff;border-radius:10px;' +
            'margin-bottom:16px;overflow:hidden;">' +
            '<tr>' +
            th('Client') + th('Sale #') +
            th('Sale Date') + th('Manager') + th('Balance Due') +
            '</tr>' +
            rows +
            '<tr><td colspan="4" style="padding:10px 12px;' +
            'font-size:12px;font-weight:700;color:#374151;' +
            'border-top:2px solid #e9d5ff;">Total Outstanding</td>' +
            '<td style="padding:10px 12px;font-size:14px;' +
            'font-weight:900;color:#dc2626;text-align:right;' +
            'border-top:2px solid #e9d5ff;">₹' +
            total.setScale(2) + '</td></tr>' +
            '</table>' +

            actionBox('#fdf4ff', '#7e22ce',
                'This Week\'s Action Plan',
                new List<String>{
                    '<strong>1</strong>&nbsp;&nbsp;' +
                    'Prioritise the highest balances first.',
                    '<strong>2</strong>&nbsp;&nbsp;' +
                    'Call or visit clients in person this week.',
                    '<strong>3</strong>&nbsp;&nbsp;' +
                    'Log every payment in Salesforce immediately ' +
                    '— updates balances in real time.'
                });

        return emailWrap(
            '#1f1235', '#f472b6',
            'WEEKLY REPORT', '#2d1b4e', '#f9a8d4',
            'Pending Payments — ' + count + ' Clients',
            'Week of ' + Date.today().format() + ' · Action Required',
            body, '#fdf4ff', '#d8b4fe'
        );
    }
}