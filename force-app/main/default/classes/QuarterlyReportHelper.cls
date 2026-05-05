public class QuarterlyReportHelper {

    // ── Entry point called by scheduler ───────────────────────────────────
    public static void sendQuarterlyReport() {
        // Determine which quarter just ended
        Date today         = Date.today();
        Integer month      = today.month();
        Integer year       = today.year();

        // Current quarter start = today (it's the 1st of a new quarter)
        // Previous quarter = the one that just ended
        Integer prevQtrNum;
        Integer prevYear = year;

        if      (month == 1)  { prevQtrNum = 4; prevYear = year - 1; }
        else if (month == 4)  { prevQtrNum = 1; }
        else if (month == 7)  { prevQtrNum = 2; }
        else                  { prevQtrNum = 3; }

        String quarter = 'Qtr' + prevQtrNum + '_' + prevYear;

        // Date range for the quarter
        Integer startMonth = (prevQtrNum - 1) * 3 + 1;
        Date qStart = Date.newInstance(prevYear, startMonth, 1);
        Date qEnd   = qStart.addMonths(3).addDays(-1);

        // Also compute previous-previous quarter for comparison
        Integer ppQtrNum = prevQtrNum == 1 ? 4 : prevQtrNum - 1;
        Integer ppYear   = prevQtrNum == 1 ? prevYear - 1 : prevYear;
        String  ppQuarter = 'Qtr' + ppQtrNum + '_' + ppYear;
        Integer ppStartMonth = (ppQtrNum - 1) * 3 + 1;
        Date    ppStart = Date.newInstance(ppYear, ppStartMonth, 1);
        Date    ppEnd   = ppStart.addMonths(3).addDays(-1);

        Map<String, Object> metrics    = gatherMetrics(qStart, qEnd, quarter);
        Map<String, Object> prevMetrics = gatherMetrics(ppStart, ppEnd, ppQuarter);

        String html = buildEmail(quarter, qStart, qEnd, metrics, prevMetrics);

        List<String> admins = getAdminEmails();
        sendEmail(
            '📊 Quarterly Results — ' + quarter +
            ' | Foxnutt Makhana Business',
            html, admins
        );
    }

    // ── Allow manual trigger with explicit quarter ─────────────────────────
    public static void sendQuarterlyReportForQuarter(String quarter) {
        List<String> parts  = quarter.split('_');
        Integer qtrNum  = Integer.valueOf(parts[0].replace('Qtr',''));
        Integer yr      = Integer.valueOf(parts[1]);
        Integer startMo = (qtrNum - 1) * 3 + 1;
        Date qStart     = Date.newInstance(yr, startMo, 1);
        Date qEnd       = qStart.addMonths(3).addDays(-1);

        Integer ppQtrNum = qtrNum == 1 ? 4 : qtrNum - 1;
        Integer ppYear   = qtrNum == 1 ? yr - 1 : yr;
        String  ppQ      = 'Qtr' + ppQtrNum + '_' + ppYear;
        Integer ppMo     = (ppQtrNum - 1) * 3 + 1;
        Date    ppStart  = Date.newInstance(ppYear, ppMo, 1);
        Date    ppEnd    = ppStart.addMonths(3).addDays(-1);

        Map<String, Object> metrics     = gatherMetrics(qStart, qEnd, quarter);
        Map<String, Object> prevMetrics = gatherMetrics(ppStart, ppEnd, ppQ);

        String html = buildEmail(quarter, qStart, qEnd, metrics, prevMetrics);
        sendEmail(
            '📊 Quarterly Results — ' + quarter + ' | Foxnutt Makhana Business',
            html, getAdminEmails()
        );
    }

    // ════════════════════════════════════════════════════════════════════════
    // METRICS GATHERING
    // ════════════════════════════════════════════════════════════════════════
    private static Map<String, Object> gatherMetrics(
        Date startDate, Date endDate, String quarter
    ) {
        Map<String, Object> m = new Map<String, Object>();

        // ── 1. Revenue & Sales ─────────────────────────────────────────────
        AggregateResult revAR = [
            SELECT SUM(Total_Revenue__c) revenue,
                   SUM(Total_Profit__c)  profit,
                   SUM(Total_Collected__c) collected,
                   COUNT(Id) saleCount
            FROM Sale__c
            WHERE Sale_Date__c >= :startDate
            AND   Sale_Date__c <= :endDate
            AND   Order_Status__c != 'Cancelled'
        ];
        Decimal revenue   = (Decimal) revAR.get('revenue');
        Decimal profit    = (Decimal) revAR.get('profit');
        Decimal collected = (Decimal) revAR.get('collected');
        Integer saleCount = Integer.valueOf(revAR.get('saleCount'));
        revenue   = revenue   != null ? revenue   : 0;
        profit    = profit    != null ? profit    : 0;
        collected = collected != null ? collected : 0;

        m.put('revenue',        revenue);
        m.put('profit',         profit);
        m.put('collected',      collected);
        m.put('saleCount',      saleCount);
        m.put('avgOrderValue',  saleCount > 0 ? revenue / saleCount : 0);
        m.put('profitMargin',   revenue > 0 ? (profit / revenue * 100) : 0);
        m.put('collectionRate', revenue > 0 ? (collected / revenue * 100) : 0);
        m.put('outstanding',    revenue - collected);

        // ── 2. KG Sold ─────────────────────────────────────────────────────
        AggregateResult kgAR = [
            SELECT SUM(Quantity__c) totalKg
            FROM Sale_Line_Item__c
            WHERE Sale__r.Sale_Date__c >= :startDate
            AND   Sale__r.Sale_Date__c <= :endDate
            AND   Sale__r.Order_Status__c != 'Cancelled'
        ];
        Decimal kgSold = (Decimal) kgAR.get('totalKg');
        kgSold = kgSold != null ? kgSold : 0;
        m.put('kgSold', kgSold);
        m.put('revenuePerKg', kgSold > 0 ? (revenue / kgSold) : 0);
        m.put('profitPerKg',  kgSold > 0 ? (profit  / kgSold) : 0);

        // ── 3. Client metrics ──────────────────────────────────────────────
        AggregateResult clientAR = [
            SELECT COUNT_DISTINCT(Client__c) activeClients
            FROM Sale__c
            WHERE Sale_Date__c >= :startDate
            AND   Sale_Date__c <= :endDate
            AND   Order_Status__c != 'Cancelled'
        ];
        m.put('activeClients',
            Integer.valueOf(clientAR.get('activeClients')));

        // Outstanding as of today
        AggregateResult outAR = [
            SELECT SUM(Balance_Due__c) total
            FROM Sale__c
            WHERE Order_Status__c != 'Cancelled'
            AND   Balance_Due__c > 0
        ];
        Decimal totalOutstanding = (Decimal) outAR.get('total');
        m.put('totalOutstandingNow',
            totalOutstanding != null ? totalOutstanding : 0);

        // Top 3 clients by revenue this quarter
        List<AggregateResult> topClients = [
            SELECT Client__r.Name clientName,
                   SUM(Total_Revenue__c) rev,
                   SUM(Total_Profit__c) pft,
                   COUNT(Id) cnt
            FROM Sale__c
            WHERE Sale_Date__c >= :startDate
            AND   Sale_Date__c <= :endDate
            AND   Order_Status__c != 'Cancelled'
            GROUP BY Client__r.Name
            ORDER BY SUM(Total_Revenue__c) DESC
            LIMIT 3
        ];
        m.put('topClients', topClients);

        // ── 4. Brand performance ───────────────────────────────────────────
        List<AggregateResult> brandPerf = [
            SELECT Brand__c brand,
                   SUM(Quantity__c) qty,
                   SUM(Line_Profit__c) profit
            FROM Sale_Line_Item__c
            WHERE Sale__r.Sale_Date__c >= :startDate
            AND   Sale__r.Sale_Date__c <= :endDate
            AND   Sale__r.Order_Status__c != 'Cancelled'
            GROUP BY Brand__c
            ORDER BY SUM(Quantity__c) DESC
            LIMIT 7
        ];
        m.put('brandPerf', brandPerf);

        // ── 5. Team performance ────────────────────────────────────────────
        List<AggregateResult> teamPerf = [
            SELECT Regional_Manager__c manager,
                   SUM(Total_Revenue__c) rev,
                   COUNT(Id) cnt
            FROM Sale__c
            WHERE Sale_Date__c >= :startDate
            AND   Sale_Date__c <= :endDate
            AND   Order_Status__c != 'Cancelled'
            AND   Regional_Manager__c != null
            GROUP BY Regional_Manager__c
            ORDER BY SUM(Total_Revenue__c) DESC
        ];
        m.put('teamPerf', teamPerf);

        // Team collections
        List<AggregateResult> teamCollections = [
            SELECT Accepted_By__c collector,
                   SUM(Amount__c) collected
            FROM Client_Payment__c
            WHERE Payment_Date__c >= :startDate
            AND   Payment_Date__c <= :endDate
            AND   Accepted_By__c != null
            GROUP BY Accepted_By__c
            ORDER BY SUM(Amount__c) DESC
        ];
        m.put('teamCollections', teamCollections);

        // ── 6. Purchases & Inventory ───────────────────────────────────────
        AggregateResult purAR = [
            SELECT SUM(Total_Order_Cost__c) cost,
                   SUM(Tax_Amount__c) tax,
                   SUM(Total_Paid__c) paid,
                   COUNT(Id) cnt
            FROM Purchase__c
            WHERE Order_Date__c >= :startDate
            AND   Order_Date__c <= :endDate
        ];
        Decimal purCost = (Decimal) purAR.get('cost');
        Decimal purTax  = (Decimal) purAR.get('tax');
        Decimal purPaid = (Decimal) purAR.get('paid');
        purCost = purCost != null ? purCost : 0;
        purTax  = purTax  != null ? purTax  : 0;
        purPaid = purPaid != null ? purPaid : 0;
        m.put('purCost',      purCost);
        m.put('purTax',       purTax);
        m.put('purTotalDue',  purCost + purTax);
        m.put('purPaid',      purPaid);
        m.put('purOwed',      Math.max(0, purCost + purTax - purPaid));
        m.put('purCount',     Integer.valueOf(purAR.get('cnt')));

        AggregateResult kgBoughtAR = [
            SELECT SUM(Quantity__c) qty
            FROM Purchase_Line_Item__c
            WHERE Purchase__r.Order_Date__c >= :startDate
            AND   Purchase__r.Order_Date__c <= :endDate
        ];
        Decimal kgBought = (Decimal) kgBoughtAR.get('qty');
        m.put('kgBought', kgBought != null ? kgBought : 0);

        // Live inventory snapshot
        AggregateResult invAR = [
            SELECT SUM(Remaining_Quantity__c) remaining,
                   COUNT(Id) brands
            FROM Inventory__c
        ];
        m.put('invRemaining',
            invAR.get('remaining') != null ? invAR.get('remaining') : 0);
        m.put('invBrands',
            Integer.valueOf(invAR.get('brands')));

        // ── 7. Cash flow ───────────────────────────────────────────────────
        AggregateResult expAR = [
            SELECT SUM(Amount__c) total
            FROM Expense__c
            WHERE Expense_Date__c >= :startDate
            AND   Expense_Date__c <= :endDate
        ];
        Decimal expenses = (Decimal) expAR.get('total');
        expenses = expenses != null ? expenses : 0;
        m.put('expenses', expenses);

        Decimal mfrPaid = 0;
        AggregateResult mfrAR = [
            SELECT SUM(Amount_Paid__c) total
            FROM Manufacturer_Payment__c
            WHERE Payment_Date__c >= :startDate
            AND   Payment_Date__c <= :endDate
        ];
        mfrPaid = (Decimal) mfrAR.get('total');
        mfrPaid = mfrPaid != null ? mfrPaid : 0;
        m.put('mfrPaid',  mfrPaid);
        m.put('netCash',  collected - mfrPaid - expenses);

        // Delivery stats — separate COUNT queries (SOQL has no SUM(CASE))
        Integer delivered = [
            SELECT COUNT() FROM Sale__c
            WHERE Sale_Date__c >= :startDate
            AND   Sale_Date__c <= :endDate
            AND   Order_Status__c = 'Delivered'
        ];
        Integer cancelled = [
            SELECT COUNT() FROM Sale__c
            WHERE Sale_Date__c >= :startDate
            AND   Sale_Date__c <= :endDate
            AND   Order_Status__c = 'Cancelled'
        ];
        m.put('deliveredCount', delivered);
        m.put('cancelledCount', cancelled);

        return m;
    }

    // ════════════════════════════════════════════════════════════════════════
    // EMAIL BUILDER
    // ════════════════════════════════════════════════════════════════════════
    private static String buildEmail(
        String quarter, Date qStart, Date qEnd,
        Map<String, Object> m, Map<String, Object> prev
    ) {
        Decimal revenue   = (Decimal) m.get('revenue');
        Decimal profit    = (Decimal) m.get('profit');
        Decimal collected = (Decimal) m.get('collected');
        Decimal expenses  = (Decimal) m.get('expenses');
        Decimal mfrPaid   = (Decimal) m.get('mfrPaid');
        Decimal netCash   = (Decimal) m.get('netCash');
        Decimal margin    = (Decimal) m.get('profitMargin');
        Decimal collRate  = (Decimal) m.get('collectionRate');
        Decimal outstanding = (Decimal) m.get('outstanding');
        Decimal kgSold    = (Decimal) m.get('kgSold');
        Decimal kgBought  = (Decimal) m.get('kgBought');
        Integer saleCount = (Integer) m.get('saleCount');
        Integer activeClients = (Integer) m.get('activeClients');

        Decimal prevRevenue = (Decimal) prev.get('revenue');
        Decimal prevProfit  = (Decimal) prev.get('profit');
        prevRevenue = prevRevenue != null ? prevRevenue : 0;
        prevProfit  = prevProfit  != null ? prevProfit  : 0;

        // Growth calculations
        Decimal revGrowth = prevRevenue > 0
            ? ((revenue - prevRevenue) / prevRevenue * 100) : 0;
        Decimal profitGrowth = prevProfit > 0
            ? ((profit - prevProfit) / prevProfit * 100) : 0;

        String revGrowthStr = (revGrowth >= 0 ? '▲ +' : '▼ ') +
            revGrowth.setScale(1) + '% vs last quarter';
        String profGrowthStr = (profitGrowth >= 0 ? '▲ +' : '▼ ') +
            profitGrowth.setScale(1) + '% vs last quarter';
        String revGrowthColor = revGrowth >= 0 ? '#16a34a' : '#dc2626';
        String profGrowthColor = profitGrowth >= 0 ? '#16a34a' : '#dc2626';

        // ── Header ─────────────────────────────────────────────────────────
        String html =
        '<!DOCTYPE html><html><body style="margin:0;padding:0;background:#0a0a0a;' +
        'font-family:Helvetica Neue,Arial,sans-serif;">' +
        '<table width="100%" cellpadding="0" cellspacing="0">' +
        '<tr><td align="center" style="padding:24px 16px;">' +
        '<table width="620" cellpadding="0" cellspacing="0" style="max-width:620px;' +
        'background:#111827;border-radius:16px;overflow:hidden;' +
        'border:1px solid #1f2937;">' +

        // Top banner
        '<tr><td style="background:linear-gradient(135deg,#f59e0b 0%,#d97706 100%);' +
        'padding:32px 36px;">' +
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
        '<td><div style="font-size:11px;font-weight:700;color:rgba(0,0,0,.6);' +
        'text-transform:uppercase;letter-spacing:.1em;margin-bottom:6px;">' +
        '🌾 FOXNUTT MAKHANA BUSINESS</div>' +
        '<div style="font-size:30px;font-weight:900;color:#000;line-height:1.1;">' +
        'Quarterly Results</div>' +
        '<div style="font-size:30px;font-weight:900;color:#000;line-height:1.1;' +
        'margin-bottom:12px;">' + quarter + '</div>' +
        '<div style="font-size:12px;color:rgba(0,0,0,.6);">' +
        qStart.format() + ' — ' + qEnd.format() + '</div></td>' +
        '<td align="right" valign="top">' +
        '<div style="background:rgba(0,0,0,.15);border-radius:10px;' +
        'padding:12px 16px;text-align:center;">' +
        '<div style="font-size:10px;font-weight:700;color:rgba(0,0,0,.5);' +
        'text-transform:uppercase;">TOTAL SALES</div>' +
        '<div style="font-size:28px;font-weight:900;color:#000;">' +
        saleCount + '</div>' +
        '<div style="font-size:10px;color:rgba(0,0,0,.5);">orders this quarter</div>' +
        '</div></td>' +
        '</tr></table></td></tr>' +

        // ── KPI Strip ──────────────────────────────────────────────────────
        '<tr><td style="background:#1f2937;padding:0;">' +
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
        kpiCell('REVENUE', '₹' + fmtCr(revenue), revGrowthStr, revGrowthColor) +
        kpiCell('GROSS PROFIT', '₹' + fmtCr(profit), profGrowthStr, profGrowthColor) +
        kpiCell('MARGIN', margin.setScale(1) + '%',
            margin >= 15 ? '✓ Healthy' : '⚠ Below 15%',
            margin >= 15 ? '#16a34a' : '#f59e0b') +
        kpiCell('COLLECTED', '₹' + fmtCr(collected),
            collRate.setScale(0) + '% collection rate',
            collRate >= 80 ? '#16a34a' : '#f59e0b') +
        '</tr></table></td></tr>' +

        // ── Section: Revenue Deep Dive ─────────────────────────────────────
        '<tr><td style="padding:28px 36px 0;">' +
        sectionTitle('📈 Revenue & Profitability') +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        twoCol(
            statBox('Total Revenue', '₹' + fmt(revenue), '#f59e0b', '#1f2937') +
            statBox('Gross Profit', '₹' + fmt(profit), '#4ade80', '#1f2937'),
            statBox('Avg Order Value',
                '₹' + fmt((Decimal)m.get('avgOrderValue')), '#818cf8', '#1f2937') +
            statBox('Revenue / KG',
                '₹' + fmt((Decimal)m.get('revenuePerKg')), '#38bdf8', '#1f2937')
        ) +
        '</td></tr>' +

        // Profit breakdown table
        '<tr><td style="padding:12px 36px 0;">' +
        darkTable(
            new List<String>{'Metric','This Quarter','Last Quarter','Change'},
            new List<List<String>>{
                new List<String>{'Revenue',
                    '₹'+fmt(revenue), '₹'+fmt(prevRevenue),
                    delta(revenue,prevRevenue)},
                new List<String>{'Gross Profit',
                    '₹'+fmt(profit), '₹'+fmt(prevProfit),
                    delta(profit,prevProfit)},
                new List<String>{'Profit Margin',
                    margin.setScale(1)+'%',
                    prevRevenue > 0
                        ? ((Decimal)prev.get('profitMargin')).setScale(1)+'%'
                        : '—',
                    ''},
                new List<String>{'KG Sold',
                    fmtN(kgSold)+' KG',
                    fmtN((Decimal)prev.get('kgSold'))+' KG',
                    delta(kgSold,(Decimal)prev.get('kgSold'))}
            }
        ) +
        '</td></tr>' +

        // ── Section: Client Performance ────────────────────────────────────
        '<tr><td style="padding:24px 36px 0;">' +
        sectionTitle('🏪 Client Performance') +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        twoCol(
            statBox('Active Clients', String.valueOf(activeClients), '#f59e0b', '#1f2937') +
            statBox('Outstanding Due', '₹'+fmtCr((Decimal)m.get('totalOutstandingNow')), '#f87171', '#1f2937'),
            statBox('Collection Rate', collRate.setScale(0)+'%', '#4ade80', '#1f2937') +
            statBox('Orders Delivered', String.valueOf((Integer)m.get('deliveredCount')), '#38bdf8', '#1f2937')
        ) +
        '</td></tr>' +

        // Top clients
        '<tr><td style="padding:12px 36px 0;">' +
        buildTopClientsTable((List<AggregateResult>)m.get('topClients'), revenue) +
        '</td></tr>' +

        // ── Section: Brand Performance ─────────────────────────────────────
        '<tr><td style="padding:24px 36px 0;">' +
        sectionTitle('🌾 Brand Performance') +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        buildBrandTable((List<AggregateResult>)m.get('brandPerf')) +
        '</td></tr>' +

        // ── Section: Team Performance ──────────────────────────────────────
        '<tr><td style="padding:24px 36px 0;">' +
        sectionTitle('👥 Team Performance') +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        buildTeamTable(
            (List<AggregateResult>)m.get('teamPerf'),
            (List<AggregateResult>)m.get('teamCollections')
        ) +
        '</td></tr>' +

        // ── Section: Purchases & Inventory ─────────────────────────────────
        '<tr><td style="padding:24px 36px 0;">' +
        sectionTitle('📦 Purchases & Inventory') +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        twoCol(
            statBox('KG Purchased', fmtN((Decimal)m.get('kgBought'))+' KG', '#a78bfa', '#1f2937') +
            statBox('Purchase Cost', '₹'+fmtCr((Decimal)m.get('purCost')), '#f59e0b', '#1f2937'),
            statBox('Tax Paid', '₹'+fmt((Decimal)m.get('purTax')), '#fbbf24', '#1f2937') +
            statBox('Still Owed to Mfr', '₹'+fmtCr((Decimal)m.get('purOwed')), '#f87171', '#1f2937')
        ) +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        darkTable(
            new List<String>{'','Amount'},
            new List<List<String>>{
                new List<String>{'Purchase Orders Placed', String.valueOf((Integer)m.get('purCount'))},
                new List<String>{'Total Order Cost', '₹'+fmt((Decimal)m.get('purCost'))},
                new List<String>{'+ Tax Paid', '₹'+fmt((Decimal)m.get('purTax'))},
                new List<String>{'= Total Due to Manufacturers', '₹'+fmt((Decimal)m.get('purTotalDue'))},
                new List<String>{'Paid to Manufacturers', '₹'+fmt((Decimal)m.get('purPaid'))},
                new List<String>{'Still Outstanding to Mfr', '₹'+fmt((Decimal)m.get('purOwed'))},
                new List<String>{'Remaining Inventory (live)', fmtN((Decimal)m.get('invRemaining'))+' KG'}
            }
        ) +
        '</td></tr>' +

        // ── Section: Cash Flow ─────────────────────────────────────────────
        '<tr><td style="padding:24px 36px 0;">' +
        sectionTitle('💵 Cash Flow') +
        '</td></tr>' +
        '<tr><td style="padding:12px 36px 0;">' +
        cashFlowBlock(collected, mfrPaid, expenses, netCash) +
        '</td></tr>' +

        // ── Footer ─────────────────────────────────────────────────────────
        '<tr><td style="padding:28px 36px;">' +
        '<div style="border-top:1px solid #374151;padding-top:20px;' +
        'font-size:11px;color:#6b7280;text-align:center;line-height:1.8;">' +
        'Foxnutt Makhana Business · Bangalore, India<br>' +
        'Quarterly report auto-generated on ' + Date.today().format() + '<br>' +
        '<span style="color:#374151;">' + quarter + '</span> · ' +
        qStart.format() + ' to ' + qEnd.format() +
        '</div></td></tr>' +

        '</table></td></tr></table></body></html>';

        return html;
    }

    // ════════════════════════════════════════════════════════════════════════
    // HTML COMPONENT HELPERS
    // ════════════════════════════════════════════════════════════════════════

    private static String kpiCell(
        String label, String value, String sub, String subColor
    ) {
        return
        '<td style="padding:16px;border-right:1px solid #374151;' +
        'text-align:center;width:25%;">' +
        '<div style="font-size:10px;font-weight:700;color:#6b7280;' +
        'text-transform:uppercase;letter-spacing:.08em;margin-bottom:4px;">' +
        label + '</div>' +
        '<div style="font-size:20px;font-weight:900;color:#f9fafb;' +
        'margin-bottom:3px;">' + value + '</div>' +
        '<div style="font-size:10px;color:' + subColor + ';font-weight:600;">' +
        sub + '</div>' +
        '</td>';
    }

    private static String sectionTitle(String title) {
        return
        '<div style="font-size:13px;font-weight:800;color:#f9fafb;' +
        'padding-bottom:8px;border-bottom:2px solid #f59e0b;' +
        'margin-bottom:4px;">' + title + '</div>';
    }

    private static String statBox(
        String label, String value, String valueColor, String bg
    ) {
        return
        '<div style="background:' + bg + ';border:1px solid #374151;' +
        'border-radius:10px;padding:14px 16px;margin-bottom:8px;">' +
        '<div style="font-size:10px;font-weight:700;color:#6b7280;' +
        'text-transform:uppercase;letter-spacing:.06em;margin-bottom:4px;">' +
        label + '</div>' +
        '<div style="font-size:18px;font-weight:800;color:' + valueColor + ';">' +
        value + '</div>' +
        '</div>';
    }

    private static String twoCol(String left, String right) {
        return
        '<table width="100%" cellpadding="0" cellspacing="0"><tr>' +
        '<td width="49%" valign="top">' + left + '</td>' +
        '<td width="2%"></td>' +
        '<td width="49%" valign="top">' + right + '</td>' +
        '</tr></table>';
    }

    private static String darkTable(
        List<String> headers, List<List<String>> rows
    ) {
        String html =
        '<table width="100%" cellpadding="0" cellspacing="0" style="' +
        'background:#1f2937;border-radius:10px;overflow:hidden;' +
        'border:1px solid #374151;margin-bottom:8px;"><tr>';

        for (String h : headers) {
            html +=
            '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
            'font-weight:700;text-transform:uppercase;letter-spacing:.06em;' +
            'color:#6b7280;text-align:left;border-bottom:1px solid #374151;">' +
            h + '</th>';
        }
        html += '</tr>';

        Boolean alt = false;
        for (List<String> row : rows) {
            String bg = alt ? '#1a2332' : '#1f2937';
            html += '<tr style="background:' + bg + ';">';
            for (Integer i = 0; i < row.size(); i++) {
                String val = row[i];
                Boolean isAmount = val.startsWith('₹') || val.contains('%');
                Boolean isChange = val.startsWith('▲') || val.startsWith('▼');
                String color = '#d1d5db';
                if (isChange && val.startsWith('▲')) color = '#4ade80';
                if (isChange && val.startsWith('▼')) color = '#f87171';
                if (i == 0) color = '#f9fafb';
                html +=
                '<td style="padding:10px 14px;font-size:12px;color:' +
                color + ';border-bottom:1px solid #374151;' +
                (i > 0 ? 'text-align:right;' : '') +
                '">' + val + '</td>';
            }
            html += '</tr>';
            alt = !alt;
        }
        html += '</table>';
        return html;
    }

    private static String buildTopClientsTable(
        List<AggregateResult> clients, Decimal totalRevenue
    ) {
        String html =
        '<table width="100%" cellpadding="0" cellspacing="0" style="' +
        'background:#1f2937;border-radius:10px;overflow:hidden;' +
        'border:1px solid #374151;margin-bottom:8px;">' +
        '<tr>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:left;border-bottom:1px solid #374151;">#</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:left;border-bottom:1px solid #374151;">Client</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Revenue</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Share</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Orders</th>' +
        '</tr>';

        String[] medals = new String[]{'🥇', '🥈', '🥉'};
        for (Integer i = 0; i < clients.size(); i++) {
            AggregateResult ar = clients[i];
            Decimal rev   = (Decimal) ar.get('rev');
            Decimal share = totalRevenue > 0 ? (rev / totalRevenue * 100) : 0;
            html +=
            '<tr style="background:' + (i == 0 ? '#1a2332' : '#1f2937') + ';">' +
            '<td style="padding:10px 14px;font-size:13px;' +
            'border-bottom:1px solid #374151;">' + medals[i] + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;font-weight:600;' +
            'color:#f9fafb;border-bottom:1px solid #374151;">' +
            (String) ar.get('clientName') + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;font-weight:700;' +
            'color:#f59e0b;text-align:right;border-bottom:1px solid #374151;">' +
            '₹' + fmt(rev) + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#9ca3af;' +
            'text-align:right;border-bottom:1px solid #374151;">' +
            share.setScale(0) + '%</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#d1d5db;' +
            'text-align:right;border-bottom:1px solid #374151;">' +
            ar.get('cnt') + '</td>' +
            '</tr>';
        }
        html += '</table>';
        return html;
    }

    private static String buildBrandTable(List<AggregateResult> brands) {
        String html =
        '<table width="100%" cellpadding="0" cellspacing="0" style="' +
        'background:#1f2937;border-radius:10px;overflow:hidden;' +
        'border:1px solid #374151;margin-bottom:8px;">' +
        '<tr>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:left;border-bottom:1px solid #374151;">Brand</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">KG Sold</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Profit</th>' +
        '</tr>';

        Boolean alt = false;
        for (AggregateResult ar : brands) {
            Decimal qty = (Decimal) ar.get('qty');
            Decimal pft = (Decimal) ar.get('profit');
            qty = qty != null ? qty : 0;
            pft = pft != null ? pft : 0;
            html +=
            '<tr style="background:' + (alt ? '#1a2332' : '#1f2937') + ';">' +
            '<td style="padding:10px 14px;font-size:12px;font-weight:600;' +
            'color:#f9fafb;border-bottom:1px solid #374151;">' +
            (String) ar.get('brand') + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#a78bfa;' +
            'font-weight:600;text-align:right;border-bottom:1px solid #374151;">' +
            fmtN(qty) + ' KG</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#4ade80;' +
            'font-weight:700;text-align:right;border-bottom:1px solid #374151;">' +
            '₹' + fmt(pft) + '</td>' +
            '</tr>';
            alt = !alt;
        }
        html += '</table>';
        return html;
    }

    private static String buildTeamTable(
        List<AggregateResult> sales, List<AggregateResult> collections
    ) {
        // Merge into one map by name
        Map<String, Decimal> collMap = new Map<String, Decimal>();
        for (AggregateResult ar : collections) {
            String name = (String) ar.get('collector');
            Decimal amt = (Decimal) ar.get('collected');
            collMap.put(name, amt != null ? amt : 0);
        }

        String html =
        '<table width="100%" cellpadding="0" cellspacing="0" style="' +
        'background:#1f2937;border-radius:10px;overflow:hidden;' +
        'border:1px solid #374151;margin-bottom:8px;">' +
        '<tr>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:left;border-bottom:1px solid #374151;">Manager</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Sales</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Revenue</th>' +
        '<th style="padding:10px 14px;background:#111827;font-size:10px;' +
        'font-weight:700;text-transform:uppercase;color:#6b7280;' +
        'text-align:right;border-bottom:1px solid #374151;">Collected</th>' +
        '</tr>';

        Boolean alt = false;
        for (AggregateResult ar : sales) {
            String name   = (String)  ar.get('manager');
            Decimal rev   = (Decimal) ar.get('rev');
            Integer cnt   = Integer.valueOf(ar.get('cnt'));
            Decimal coll  = collMap.containsKey(name)
                            ? collMap.get(name) : 0;
            rev  = rev  != null ? rev  : 0;
            html +=
            '<tr style="background:' + (alt ? '#1a2332' : '#1f2937') + ';">' +
            '<td style="padding:10px 14px;font-size:12px;font-weight:700;' +
            'color:#f9fafb;border-bottom:1px solid #374151;">👤 ' +
            name + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#d1d5db;' +
            'text-align:right;border-bottom:1px solid #374151;">' +
            cnt + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#f59e0b;' +
            'font-weight:700;text-align:right;border-bottom:1px solid #374151;">' +
            '₹' + fmt(rev) + '</td>' +
            '<td style="padding:10px 14px;font-size:12px;color:#4ade80;' +
            'font-weight:700;text-align:right;border-bottom:1px solid #374151;">' +
            '₹' + fmt(coll) + '</td>' +
            '</tr>';
            alt = !alt;
        }
        html += '</table>';
        return html;
    }

    private static String cashFlowBlock(
        Decimal collected, Decimal mfrPaid,
        Decimal expenses, Decimal net
    ) {
        String netColor = net >= 0 ? '#4ade80' : '#f87171';
        return
        '<table width="100%" cellpadding="0" cellspacing="0" style="' +
        'background:#1f2937;border-radius:10px;overflow:hidden;' +
        'border:1px solid #374151;margin-bottom:8px;">' +
        cfRow('Cash Collected from Clients', '₹' + fmt(collected), '#4ade80', false) +
        cfRow('− Paid to Manufacturers',     '₹' + fmt(mfrPaid),   '#f87171', false) +
        cfRow('− Business Expenses',         '₹' + fmt(expenses),  '#f87171', false) +
        cfRowTotal('= Net Cash Position',    '₹' + fmt(net),       netColor) +
        '</table>';
    }

    private static String cfRow(
        String label, String value, String valColor, Boolean isTotal
    ) {
        return
        '<tr style="background:#1f2937;">' +
        '<td style="padding:12px 16px;font-size:12px;color:#d1d5db;' +
        'border-bottom:1px solid #374151;">' + label + '</td>' +
        '<td style="padding:12px 16px;font-size:13px;font-weight:700;' +
        'color:' + valColor + ';text-align:right;' +
        'border-bottom:1px solid #374151;">' + value + '</td>' +
        '</tr>';
    }

    private static String cfRowTotal(
        String label, String value, String valColor
    ) {
        return
        '<tr style="background:#111827;">' +
        '<td style="padding:14px 16px;font-size:13px;font-weight:800;' +
        'color:#f9fafb;">' + label + '</td>' +
        '<td style="padding:14px 16px;font-size:16px;font-weight:900;' +
        'color:' + valColor + ';text-align:right;">' + value + '</td>' +
        '</tr>';
    }

    // ── Formatting helpers ─────────────────────────────────────────────────
    private static String fmt(Decimal v) {
        if (v == null) return '0.00';
        return v.setScale(0).format();
    }

    private static String fmtCr(Decimal v) {
        if (v == null) return '0';
        if (v >= 100000) {
            Decimal lakh = v / 100000;
            return lakh.setScale(2) + 'L';
        }
        return v.setScale(0).format();
    }

    private static String fmtN(Decimal v) {
        if (v == null) return '0';
        return String.valueOf(v.setScale(1));
    }

    private static String delta(Decimal curr, Decimal prev) {
        if (curr == null) curr = 0;
        if (prev == null || prev == 0) return '—';
        Decimal pct = ((curr - prev) / prev) * 100;
        return (pct >= 0 ? '▲ +' : '▼ ') + pct.setScale(1) + '%';
    }

    // ── Email send ─────────────────────────────────────────────────────────
    private static void sendEmail(
        String subject, String html, List<String> toAddresses
    ) {
        if (toAddresses == null || toAddresses.isEmpty()) return;
        List<OrgWideEmailAddress> owas = [
            SELECT Id FROM OrgWideEmailAddress LIMIT 1
        ];
        Messaging.SingleEmailMessage mail =
            new Messaging.SingleEmailMessage();
        mail.setToAddresses(toAddresses);
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
            System.debug('Quarterly email failed: ' + e.getMessage());
        }
    }

    private static List<String> getAdminEmails() {
        List<String> emails = new List<String>{'vikramthakur381@gmail.com'};
        return emails;
    }
}