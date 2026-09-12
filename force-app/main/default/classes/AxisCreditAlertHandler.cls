/**
 * Inbound email handler for Axis Bank credit alerts.
 *
 * Gmail auto-forwards every "INR x was credited to your A/c." mail from
 * alerts@axis.bank.in to this org's email service address. Each mail
 * becomes a Bank_Credit_Alert__c; when the payer can be tied to a client
 * with an unpaid order, a Client_Payment__c is created too, and the
 * existing ClientPaymentSummaryTrigger sends the payment-received
 * WhatsApp. Anything ambiguous is left as "Needs Review" with a Task, so
 * money is never booked against a guess.
 *
 * Axis body, as of Sept 2026:
 *   Amount Credited:   INR 290.00
 *   Date & Time:       11-09-26, 17:25:31 IST
 *   Transaction Info:  UPI/P2A/129425753659/SRIMALINI/HDFC/<remark>
 *                      UPI / type / UTR / payer / payer bank / remark
 */
global with sharing class AxisCreditAlertHandler
    implements Messaging.InboundEmailHandler {

    // Client_Payment__c.Accepted_By__c is a required team-member picklist.
    // Auto-booked receipts are attributed to the account holder.
    @TestVisible private static String ACCEPTED_BY = 'Vikram';

    private static final Pattern SALE_NAME = Pattern.compile('SAL-?\\s?(\\d{3,6})');

    public class Parsed {
        public Decimal  amount;
        public String   utr;
        public String   payer;
        public String   remark;
        public String   info;
        public Datetime creditedAt;
        public String   mode = 'UPI';
        public Boolean  isCredit = false;
    }

    global Messaging.InboundEmailResult handleInboundEmail(
        Messaging.InboundEmail email, Messaging.InboundEnvelope envelope
    ) {
        Messaging.InboundEmailResult result = new Messaging.InboundEmailResult();
        // Never bounce: a rejected mail would vanish, a logged one can be
        // fixed by hand.
        result.success = true;
        try {
            process(email.subject, bodyOf(email));
        } catch (Exception e) {
            try {
                insert new Bank_Credit_Alert__c(
                    Subject__c      = left(email.subject, 255),
                    Raw_Body__c     = left(bodyOf(email), 32000),
                    Status__c       = 'Needs Review',
                    Match_Reason__c = left('Handler error: ' + e.getMessage(), 255)
                );
            } catch (Exception ignored) {}
        }
        return result;
    }

    // ── Core, callable from tests without the Messaging plumbing ─────────
    public static Bank_Credit_Alert__c process(String subject, String body) {
        Parsed p = parse(subject, body);

        Bank_Credit_Alert__c alert = new Bank_Credit_Alert__c(
            Subject__c          = left(subject, 255),
            Raw_Body__c         = left(body, 32000),
            Amount__c           = p.amount,
            UTR__c              = p.utr,
            Payer_Name__c       = left(p.payer, 120),
            Remark__c           = left(p.remark, 120),
            Transaction_Info__c = left(p.info, 255),
            Credited_At__c      = p.creditedAt
        );

        if (!p.isCredit) {
            alert.Status__c       = 'Not a Credit';
            alert.UTR__c          = null;   // keep the unique key for real credits
            alert.Match_Reason__c = 'No "Amount Credited" found in this mail.';
            insert alert;
            return alert;
        }

        if (p.utr != null && 0 < [
            SELECT COUNT() FROM Bank_Credit_Alert__c WHERE UTR__c = :p.utr
        ]) {
            alert.Status__c       = 'Duplicate';
            alert.UTR__c          = null;
            alert.Match_Reason__c = 'UTR ' + p.utr + ' already processed.';
            insert alert;
            return alert;
        }

        Match m = findMatch(p);
        if (m == null) {
            alert.Status__c       = 'Needs Review';
            alert.Match_Reason__c = 'Could not tie this credit to a client. ' +
                'Add the payment by hand from the client\'s page.';
            insert alert;
            NotificationHelper.notifyUnmatchedCredit(alert);
            return alert;
        }

        List<Client_Payment__c> payments = allocate(m, p);
        insert payments;   // trigger: WhatsApp + email + balances
        rememberPayer(m.clientId, p.payer);

        alert.Status__c         = 'Matched';
        alert.Client__c         = m.clientId;
        alert.Sale__c           = payments[0].Sale__c;
        alert.Client_Payment__c = payments[0].Id;
        alert.Match_Reason__c   = left(m.reason +
            (payments.size() > 1
                ? ' Split across ' + payments.size() + ' orders.' : ''), 255);
        insert alert;
        return alert;
    }

    // ── Parsing ──────────────────────────────────────────────────────────
    public static Parsed parse(String subject, String body) {
        Parsed p = new Parsed();
        String text = (body == null ? '' : body)
            .replace('&amp;', '&').replace(' ', ' ');
        String subj = subject == null ? '' : subject;

        p.amount = firstDecimal(text,
            '(?i)Amount\\s*Credited\\s*:?\\s*(?:INR|Rs\\.?|₹)?\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)');
        if (p.amount == null) {
            p.amount = firstDecimal(subj,
                '(?i)(?:INR|Rs\\.?|₹)\\s*([0-9][0-9,]*(?:\\.[0-9]+)?)\\s*(?:was|has been)\\s*credited');
        }
        p.isCredit = p.amount != null && p.amount > 0
            && (subj + ' ' + text).toLowerCase().contains('credited');

        Matcher mi = Pattern.compile('(?i)Transaction\\s*Info\\s*:?\\s*([^\\r\\n]+)')
            .matcher(text);
        if (mi.find()) p.info = mi.group(1).trim();

        if (p.info != null) {
            List<String> parts = p.info.split('/');
            String kind = parts[0].trim().toUpperCase();
            if (kind == 'UPI' && parts.size() >= 4) {
                p.utr   = parts[2].trim();
                p.payer = parts[3].trim();
                List<String> rest = new List<String>();
                for (Integer i = 5; i < parts.size(); i++) rest.add(parts[i].trim());
                p.remark = String.join(rest, '/');
            } else {
                if (kind.startsWith('NEFT') || kind.startsWith('RTGS')
                    || kind.startsWith('IMPS')) p.mode = 'NEFT/RTGS';
                Matcher mu = Pattern.compile('(\\d{12,22})').matcher(p.info);
                if (mu.find()) p.utr = mu.group(1);
                p.remark = p.info;
            }
        }

        Matcher md = Pattern.compile(
            '(?i)Date\\s*&\\s*Time\\s*:?\\s*(\\d{2})-(\\d{2})-(\\d{2,4}),?\\s*(\\d{2}):(\\d{2})(?::(\\d{2}))?')
            .matcher(text);
        if (md.find()) {
            Integer yy = Integer.valueOf(md.group(3));
            if (yy < 100) yy += 2000;
            try {
                p.creditedAt = Datetime.newInstance(
                    yy, Integer.valueOf(md.group(2)), Integer.valueOf(md.group(1)),
                    Integer.valueOf(md.group(4)), Integer.valueOf(md.group(5)),
                    md.group(6) == null ? 0 : Integer.valueOf(md.group(6)));
            } catch (Exception ignored) {}
        }
        return p;
    }

    private static Decimal firstDecimal(String text, String regex) {
        Matcher m = Pattern.compile(regex).matcher(text);
        if (!m.find()) return null;
        try { return Decimal.valueOf(m.group(1).replace(',', '')); }
        catch (Exception e) { return null; }
    }

    // ── Matching ─────────────────────────────────────────────────────────
    public class Match {
        public Id     clientId;
        public Id     preferredSaleId;
        public String reason;
    }

    private static List<Sale__c> unpaidSales() {
        return [
            SELECT Id, Name, Client__c, Client__r.Name,
                   Client__r.Contact_Person__c,
                   Client__r.UPI_Payer_Name__c,
                   Client__r.Unique_Business_Code__c,
                   Balance_Due__c, Sale_Date__c, Order_Status__c
            FROM Sale__c
            WHERE Balance_Due__c > 0
            AND Order_Status__c NOT IN ('Cancelled', 'Pending Approval')
            ORDER BY Sale_Date__c ASC, Name ASC
        ];
    }

    @TestVisible
    private static Match findMatch(Parsed p) {
        List<Sale__c> unpaid = unpaidSales();
        if (unpaid.isEmpty()) return null;
        String haystack = ((p.info == null ? '' : p.info) + ' ' +
                           (p.remark == null ? '' : p.remark)).toUpperCase();

        // 1. Order number in the remark (SAL-0059, SAL0059, SAL 0059).
        Matcher ms = SALE_NAME.matcher(haystack);
        while (ms.find()) {
            String wanted = 'SAL-' + ms.group(1).leftPad(4, '0');
            for (Sale__c s : unpaid) {
                if (s.Name == wanted) {
                    Match m = new Match();
                    m.clientId        = s.Client__c;
                    m.preferredSaleId = s.Id;
                    m.reason          = 'Order number ' + wanted + ' in remark.';
                    return m;
                }
            }
        }

        // 2. Business code in the remark.
        for (Sale__c s : unpaid) {
            String code = s.Client__r.Unique_Business_Code__c;
            if (String.isNotBlank(code) && haystack.contains(code.toUpperCase())) {
                Match m = new Match();
                m.clientId = s.Client__c;
                m.reason   = 'Business code ' + code + ' in remark.';
                return m;
            }
        }

        // 3. A payer name we have seen before on exactly one client. This
        //    is what makes repeat customers match with no remark at all,
        //    even when two clients happen to owe the same amount.
        String payerKey = letters(p.payer);
        if (payerKey.length() >= 3) {
            Set<Id> known = new Set<Id>();
            String label;
            for (Sale__c s : unpaid) {
                if (letters(s.Client__r.UPI_Payer_Name__c) == payerKey) {
                    known.add(s.Client__c);
                    label = s.Client__r.Name;
                }
            }
            if (known.size() == 1) {
                Match m = new Match();
                m.clientId = new List<Id>(known)[0];
                m.reason   = 'Known UPI payer "' + p.payer + '" for ' + label + '.';
                return m;
            }
        }

        // 4. Exact amount owed by exactly one client.
        Set<Id> byAmount = new Set<Id>();
        Id amountSale;
        for (Sale__c s : unpaid) {
            if (s.Balance_Due__c == p.amount) {
                byAmount.add(s.Client__c);
                if (amountSale == null) amountSale = s.Id;
            }
        }
        if (byAmount.size() == 1) {
            Match m = new Match();
            m.clientId        = new List<Id>(byAmount)[0];
            m.preferredSaleId = amountSale;
            m.reason          = 'Amount equals the balance of one open order.';
            return m;
        }

        // 5. Payer name against the account or contact person, one client.
        String payer = letters(p.payer);
        if (payer.length() >= 4) {
            Set<Id> byName = new Set<Id>();
            String label;
            for (Sale__c s : unpaid) {
                if (nameHits(payer, s.Client__r.Name)
                    || nameHits(payer, s.Client__r.Contact_Person__c)) {
                    byName.add(s.Client__c);
                    label = s.Client__r.Name;
                }
            }
            if (byName.size() == 1) {
                Match m = new Match();
                m.clientId = new List<Id>(byName)[0];
                m.reason   = 'Payer "' + p.payer + '" matches client ' + label + '.';
                return m;
            }
        }
        return null;
    }

    /**
     * Store the bank's payer name on the client after a confident match,
     * so the next payment from the same UPI handle matches by name. Only
     * fills a blank: a name set by hand is never overwritten.
     */
    private static void rememberPayer(Id clientId, String payer) {
        if (clientId == null || String.isBlank(payer)) return;
        List<Account> rows = [
            SELECT Id, UPI_Payer_Name__c FROM Account WHERE Id = :clientId
        ];
        if (rows.isEmpty() || String.isNotBlank(rows[0].UPI_Payer_Name__c)) return;
        rows[0].UPI_Payer_Name__c = left(payer.trim(), 120);
        try { update rows[0]; }
        catch (Exception e) { System.debug('UPI payer not saved: ' + e.getMessage()); }
    }

    private static String letters(String s) {
        return s == null ? '' : s.replaceAll('[^A-Za-z ]', '').toUpperCase().trim();
    }

    /** True when one side's first word (4+ letters) appears in the other. */
    private static Boolean nameHits(String payer, String account) {
        String acc = letters(account);
        if (acc.length() < 4) return false;
        String payerFirst = payer.split(' ')[0];
        String accFirst   = acc.split(' ')[0];
        return (payerFirst.length() >= 4 && acc.contains(payerFirst))
            || (accFirst.length() >= 4 && payer.contains(accFirst));
    }

    // ── Allocation: oldest order first, preferred order ahead of all ─────
    private static List<Client_Payment__c> allocate(Match m, Parsed p) {
        List<Sale__c> ordered = new List<Sale__c>();
        Sale__c preferred;
        for (Sale__c s : unpaidSales()) {
            if (s.Client__c != m.clientId) continue;
            if (s.Id == m.preferredSaleId) preferred = s; else ordered.add(s);
        }
        if (preferred != null) {
            List<Sale__c> withPreferred = new List<Sale__c>{ preferred };
            withPreferred.addAll(ordered);
            ordered = withPreferred;
        }
        Date paidOn = p.creditedAt != null ? p.creditedAt.date() : Date.today();
        List<Client_Payment__c> out = new List<Client_Payment__c>();
        Decimal remaining = p.amount;
        for (Integer i = 0; i < ordered.size() && remaining > 0; i++) {
            Sale__c s = ordered[i];
            Boolean last = (i == ordered.size() - 1);
            // Any excess stays on the final order so it shows as overpaid
            // rather than being silently dropped.
            Decimal pay = last ? remaining : Math.min(remaining, s.Balance_Due__c);
            out.add(new Client_Payment__c(
                Sale__c            = s.Id,
                Amount__c          = pay,
                Payment_Date__c    = paidOn,
                Mode_of_Payment__c = p.mode,
                Accepted_By__c     = ACCEPTED_BY,
                Reference__c       = left(p.utr, 100)
            ));
            remaining -= pay;
        }
        return out;
    }

    // ── Utilities ────────────────────────────────────────────────────────
    private static String bodyOf(Messaging.InboundEmail email) {
        if (String.isNotBlank(email.plainTextBody)) return email.plainTextBody;
        if (String.isNotBlank(email.htmlBody)) {
            return email.htmlBody
                .replaceAll('(?i)<br\\s*/?>', '\n')
                .replaceAll('(?i)</(p|div|tr|td|li|h\\d)>', '\n')
                .replaceAll('<[^>]+>', ' ')
                .replaceAll('[ \\t]+', ' ');
        }
        return '';
    }

    private static String left(String s, Integer n) {
        if (s == null) return null;
        return s.length() > n ? s.substring(0, n) : s;
    }
}
