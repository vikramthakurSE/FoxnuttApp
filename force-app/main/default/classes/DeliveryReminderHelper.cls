public class DeliveryReminderHelper {

    // ── Called by scheduler every morning at 8 AM ─────────────────────────
    public static void sendDailyReminders() {
        Date today    = Date.today();
        Date tomorrow = today.addDays(1);

        // 1. Sales due TODAY
        List<Sale__c> dueToday = [
            SELECT Id, Name, Expected_Delivery_Date__c,
                   Regional_Manager__c, Total_Revenue__c,
                   Balance_Due__c, Order_Status__c,
                   Client__r.Name, Client__r.Phone,
                   (SELECT Brand__c, Packet_Type__c,
                           Quantity__c, Rate_Per_Kg__c
                    FROM Sale_Line_Items__r)
            FROM Sale__c
            WHERE Expected_Delivery_Date__c = :today
            AND Order_Status__c IN ('Confirmed', 'Out for Delivery')
        ];

        // 2. Sales due TOMORROW
        List<Sale__c> dueTomorrow = [
            SELECT Id, Name, Expected_Delivery_Date__c,
                   Regional_Manager__c, Total_Revenue__c,
                   Balance_Due__c, Order_Status__c,
                   Client__r.Name, Client__r.Phone,
                   (SELECT Brand__c, Packet_Type__c,
                           Quantity__c, Rate_Per_Kg__c
                    FROM Sale_Line_Items__r)
            FROM Sale__c
            WHERE Expected_Delivery_Date__c = :tomorrow
            AND Order_Status__c IN ('Confirmed', 'Out for Delivery')
        ];

        List<String> admins = getAdminEmails();

        if (!dueToday.isEmpty()) {
            sendReminderEmail(dueToday, 'today', admins);
        }
        if (!dueTomorrow.isEmpty()) {
            sendReminderEmail(dueTomorrow, 'tomorrow', admins);
        }
    }

    // ── Build and send reminder email ─────────────────────────────────────
    private static void sendReminderEmail(
        List<Sale__c> sales, String day, List<String> admins
    ) {
        Boolean isToday = day == 'today';

        String hBg     = isToday ? '#7f1d1d' : '#1e3a5f';
        String badge   = isToday ? 'DELIVER TODAY' : 'DELIVER TOMORROW';
        String subject = isToday
            ? '🚨 ' + sales.size() + ' Delivery(ies) Due TODAY — Action Required'
            : '⏰ Reminder: ' + sales.size() + ' Delivery(ies) Due Tomorrow';

        // Build rows for each sale
        String saleRows = '';
        Decimal totalRevenue = 0;
        Decimal totalBalance = 0;

        for (Sale__c s : sales) {
            Decimal rev = s.Total_Revenue__c != null ? s.Total_Revenue__c : 0;
            Decimal bal = s.Balance_Due__c   != null ? s.Balance_Due__c   : 0;
            totalRevenue += rev;
            totalBalance += bal;

            // Build product summary
            String products = '';
            if (s.Sale_Line_Items__r != null) {
                for (Sale_Line_Item__c li : s.Sale_Line_Items__r) {
                    if (products != '') products += ', ';
                    products += li.Brand__c + ' ' +
                        (li.Quantity__c != null ? li.Quantity__c : 0) + ' KG';
                }
            }
            if (String.isBlank(products)) products = 'See order details';

            String manager = s.Regional_Manager__c != null
                             ? s.Regional_Manager__c : 'Unassigned';
            String phone   = s.Client__r.Phone != null
                             ? s.Client__r.Phone : '—';

            saleRows +=
                '<tr style="background:#1f2937;">' +
                '<td style="padding:12px 14px;font-size:12px;font-weight:700;' +
                'color:#f9fafb;border-bottom:1px solid #374151;">' +
                s.Client__r.Name + '</td>' +
                '<td style="padding:12px 14px;font-size:12px;color:#d1d5db;' +
                'border-bottom:1px solid #374151;">' + s.Name + '</td>' +
                '<td style="padding:12px 14px;font-size:12px;color:#a78bfa;' +
                'border-bottom:1px solid #374151;">' + manager + '</td>' +
                '<td style="padding:12px 14px;font-size:11px;color:#9ca3af;' +
                'border-bottom:1px solid #374151;">' + products + '</td>' +
                '<td style="padding:12px 14px;font-size:12px;color:#f59e0b;' +
                'font-weight:700;border-bottom:1px solid #374151;' +
                'text-align:right;">Rs ' + rev.setScale(0).format() + '</td>' +
                '<td style="padding:12px 14px;font-size:12px;font-weight:700;' +
                'color:' + (bal > 0 ? '#f87171' : '#4ade80') + ';' +
                'border-bottom:1px solid #374151;text-align:right;">' +
                (bal > 0 ? 'Rs ' + bal.setScale(0).format() + ' DUE' : 'Paid') +
                '</td>' +
                '<td style="padding:12px 14px;font-size:11px;color:#9ca3af;' +
                'border-bottom:1px solid #374151;">' + phone + '</td>' +
                '</tr>';
        }

        // Email body
        String urgencyBox = isToday
            ? '<table width="100%" cellpadding="0" cellspacing="0" ' +
              'style="background:#450a0a;border-radius:10px;' +
              'border-left:4px solid #ef4444;margin-bottom:16px;">' +
              '<tr><td style="padding:16px 20px;">' +
              '<div style="font-size:13px;font-weight:800;color:#fca5a5;' +
              'margin-bottom:6px;">URGENT — Deliveries Due Today</div>' +
              '<p style="font-size:12px;color:#fecaca;margin:0;">' +
              'Please ensure all orders below are dispatched and payment is collected.</p>' +
              '</td></tr></table>'
            : '<table width="100%" cellpadding="0" cellspacing="0" ' +
              'style="background:#1e3a5f;border-radius:10px;' +
              'border-left:4px solid #60a5fa;margin-bottom:16px;">' +
              '<tr><td style="padding:16px 20px;">' +
              '<div style="font-size:13px;font-weight:800;color:#93c5fd;' +
              'margin-bottom:6px;">Heads Up — Deliveries Due Tomorrow</div>' +
              '<p style="font-size:12px;color:#bfdbfe;margin:0;">' +
              'Prepare orders and coordinate with your team for tomorrow\'s deliveries.</p>' +
              '</td></tr></table>';

        String body = urgencyBox +
            '<table width="100%" cellpadding="0" cellspacing="0" ' +
            'style="background:#1f2937;border-radius:10px;overflow:hidden;' +
            'border:1px solid #374151;margin-bottom:16px;">' +
            '<tr>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:left;border-bottom:1px solid #374151;">Client</th>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:left;border-bottom:1px solid #374151;">Order</th>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:left;border-bottom:1px solid #374151;">Manager</th>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:left;border-bottom:1px solid #374151;">Products</th>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:right;border-bottom:1px solid #374151;">Value</th>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:right;border-bottom:1px solid #374151;">Balance</th>' +
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;color:#6b7280;' +
            'text-align:left;border-bottom:1px solid #374151;">Phone</th>' +
            '</tr>' +
            saleRows +
            '<tr style="background:#111827;">' +
            '<td colspan="4" style="padding:12px 14px;font-size:12px;' +
            'font-weight:700;color:#f9fafb;">TOTAL (' +
            sales.size() + ' orders)</td>' +
            '<td style="padding:12px 14px;font-size:13px;font-weight:900;' +
            'color:#f59e0b;text-align:right;">Rs ' +
            totalRevenue.setScale(0).format() + '</td>' +
            '<td style="padding:12px 14px;font-size:13px;font-weight:900;' +
            'color:#f87171;text-align:right;">Rs ' +
            totalBalance.setScale(0).format() + '</td>' +
            '<td></td>' +
            '</tr>' +
            '</table>';

        String html =
            '<!DOCTYPE html><html><body style="margin:0;padding:0;' +
            'background:#0a0a0a;font-family:Helvetica Neue,Arial,sans-serif;">' +
            '<table width="100%" cellpadding="0" cellspacing="0">' +
            '<tr><td align="center" style="padding:24px 16px;">' +
            '<table width="650" cellpadding="0" cellspacing="0" ' +
            'style="max-width:650px;background:#111827;border-radius:16px;' +
            'overflow:hidden;border:1px solid #1f2937;">' +
            '<tr><td style="background:' + hBg + ';padding:24px 32px;">' +
            '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
            '<td><div style="font-size:11px;font-weight:700;color:rgba(255,255,255,.5);' +
            'text-transform:uppercase;letter-spacing:.1em;margin-bottom:6px;">' +
            'MAKHANA CO. — DELIVERY REMINDER</div>' +
            '<div style="font-size:24px;font-weight:900;color:#fff;">' +
            (isToday ? 'Deliveries Due Today' : 'Deliveries Due Tomorrow') +
            '</div>' +
            '<div style="font-size:12px;color:rgba(255,255,255,.5);margin-top:4px;">' +
            Date.today().format() + '</div></td>' +
            '<td align="right"><div style="background:rgba(255,255,255,.1);' +
            'border-radius:10px;padding:10px 16px;text-align:center;">' +
            '<div style="font-size:10px;color:rgba(255,255,255,.5);' +
            'font-weight:700;text-transform:uppercase;">ORDERS</div>' +
            '<div style="font-size:28px;font-weight:900;color:#fff;">' +
            sales.size() + '</div>' +
            '</div></td></tr></table></td></tr>' +
            '<tr><td style="padding:24px 32px;">' + body + '</td></tr>' +
            '<tr><td style="padding:16px 32px;border-top:1px solid #1f2937;">' +
            '<p style="font-size:11px;color:#6b7280;margin:0;">' +
            'Automated delivery reminder · Makhana Business App</p>' +
            '</td></tr></table></td></tr></table></body></html>';

        List<OrgWideEmailAddress> owas = [
            SELECT Id FROM OrgWideEmailAddress LIMIT 1
        ];
        Messaging.SingleEmailMessage mail =
            new Messaging.SingleEmailMessage();
        mail.setToAddresses(admins);
        mail.setSubject(subject);
        mail.setHtmlBody(html);
        mail.setSaveAsActivity(false);
        if (!owas.isEmpty())
            mail.setOrgWideEmailAddressId(owas[0].Id);
        try {
            Messaging.sendEmail(
                new List<Messaging.SingleEmailMessage>{ mail }
            );
        } catch (Exception e) {
            System.debug('Delivery reminder failed: ' + e.getMessage());
        }
    }

    private static List<String> getAdminEmails() {
        List<String> emails = new List<String>{'vikramthakur381@gmail.com','rohanagarwalprp@gmail.com'};
        return emails;
    }
}