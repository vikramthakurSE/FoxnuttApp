/**
 * Delivery rules for website orders, decided by the delivery PIN code.
 *
 *   Local       — a PIN code in one of the local districts (Bangalore):
 *                 any order size, no delivery charge.
 *   Home State  — elsewhere in the home state (Karnataka): each brand in
 *                 the order must reach its minimum KG, no delivery charge.
 *   Other State — same minimums, plus a per-KG delivery charge on the whole
 *                 order, capped. No GST on the charge.
 *
 * The website resolves the PIN code to its India Post district and state;
 * Salesforce decides the zone and applies the numbers, which live in
 * Delivery_Setting__mdt (record "Default") and Delivery_Brand_Minimum__mdt
 * so they can be changed in Setup without a deploy.
 */
public without sharing class DeliveryRules {

    public static final String ZONE_LOCAL       = 'Local';
    public static final String ZONE_HOME_STATE  = 'Home State';
    public static final String ZONE_OTHER_STATE = 'Other State';

    public class Settings {
        public Set<String> localDistricts;       // upper case
        public String homeState;                 // upper case
        public Decimal defaultMinKg;
        public Decimal chargePerKg;
        public Decimal maxCharge;                // null = no cap
        public Map<String, Decimal> brandMinKg;  // lower-case brand name → KG
    }

    public class Shortfall {
        public String  brand;
        public Decimal minKg;
        public Decimal kg;
    }

    public class Quote {
        public String  zone;
        public Decimal totalKg;
        public Decimal charge;
        public List<Shortfall> shortfalls;
    }

    @TestVisible private static Settings cached;

    /**
     * Current settings. Falls back to the launch values when the Default
     * record is missing, so a deleted record never silently lifts the rules.
     */
    public static Settings settings() {
        if (cached != null) return cached;
        Settings s = new Settings();
        s.localDistricts = new Set<String>{ 'BENGALURU URBAN', 'BENGALURU RURAL' };
        s.homeState    = 'KARNATAKA';
        s.defaultMinKg = 10;
        s.chargePerKg  = 5;
        s.maxCharge    = 90;
        s.brandMinKg   = new Map<String, Decimal>();

        Delivery_Setting__mdt rec = Delivery_Setting__mdt.getInstance('Default');
        if (rec != null) {
            if (String.isNotBlank(rec.Local_Districts__c)) {
                s.localDistricts = new Set<String>();
                for (String d : rec.Local_Districts__c.split('[;,\\n]')) {
                    if (String.isNotBlank(d)) s.localDistricts.add(norm(d));
                }
            }
            if (String.isNotBlank(rec.Home_State__c)) s.homeState = norm(rec.Home_State__c);
            if (rec.Default_Min_Kg__c != null) s.defaultMinKg = rec.Default_Min_Kg__c;
            if (rec.Charge_Per_Kg__c != null)  s.chargePerKg  = rec.Charge_Per_Kg__c;
            s.maxCharge = rec.Max_Charge__c;
        }

        Map<String, Delivery_Brand_Minimum__mdt> brands = Delivery_Brand_Minimum__mdt.getAll();
        if (brands.isEmpty() && rec == null) {
            s.brandMinKg.put('holiday', 8);
        }
        for (Delivery_Brand_Minimum__mdt b : brands.values()) {
            if (String.isNotBlank(b.Brand_Name__c) && b.Min_Kg__c != null) {
                s.brandMinKg.put(b.Brand_Name__c.trim().toLowerCase(), b.Min_Kg__c);
            }
        }
        cached = s;
        return s;
    }

    /** Local when any of the PIN code's districts is local, else by state. */
    public static String zoneFor(List<String> districts, String state) {
        Settings s = settings();
        if (districts != null) {
            for (String d : districts) {
                if (String.isNotBlank(d) && s.localDistricts.contains(norm(d))) return ZONE_LOCAL;
            }
        }
        return norm(state) == s.homeState ? ZONE_HOME_STATE : ZONE_OTHER_STATE;
    }

    /**
     * Brand family used for minimums: the first word of the brand, so
     * "Holiday_250g" and "Holiday loose" count together as Holiday.
     */
    public static String brandFamily(String brand) {
        if (String.isBlank(brand)) return '';
        return brand.trim().split('[ _]')[0];
    }

    /** Minimums and charge for an order, given KG per product brand. */
    public static Quote quote(String zone, Map<String, Decimal> kgByBrand) {
        Settings s = settings();
        Quote q = new Quote();
        q.zone       = zone;
        q.totalKg    = 0;
        q.charge     = 0;
        q.shortfalls = new List<Shortfall>();

        // Keyed case-insensitively, keeping the first spelling for messages.
        Map<String, Decimal> kgByFamily = new Map<String, Decimal>();
        Map<String, String> familyLabel = new Map<String, String>();
        for (String brand : kgByBrand.keySet()) {
            Decimal kg = kgByBrand.get(brand) == null ? 0 : kgByBrand.get(brand);
            String family = brandFamily(brand);
            String key = family.toLowerCase();
            if (!familyLabel.containsKey(key)) familyLabel.put(key, family);
            kgByFamily.put(key, (kgByFamily.containsKey(key) ? kgByFamily.get(key) : 0) + kg);
            q.totalKg += kg;
        }

        // Orders from before PIN codes were checked have no zone: no rules.
        if (String.isBlank(zone) || zone == ZONE_LOCAL) return q;

        for (String key : kgByFamily.keySet()) {
            Decimal min = s.brandMinKg.containsKey(key) ? s.brandMinKg.get(key) : s.defaultMinKg;
            if (kgByFamily.get(key) < min) {
                Shortfall f = new Shortfall();
                f.brand = familyLabel.get(key);
                f.minKg = min;
                f.kg    = kgByFamily.get(key);
                q.shortfalls.add(f);
            }
        }

        if (zone == ZONE_OTHER_STATE) {
            Decimal charge = q.totalKg * s.chargePerKg;
            if (s.maxCharge != null && charge > s.maxCharge) charge = s.maxCharge;
            q.charge = charge.setScale(2, RoundingMode.HALF_UP);
        }
        return q;
    }

    /** Customer-facing reason an order misses its minimums. */
    public static String shortfallMessage(Quote q) {
        List<String> parts = new List<String>();
        for (Shortfall f : q.shortfalls) {
            parts.add(f.brand + ' needs at least ' + kgText(f.minKg) +
                ' (you have ' + kgText(f.kg) + ')');
        }
        return 'For delivery to this PIN code each brand has a minimum order: ' +
            String.join(parts, '; ') + '.';
    }

    /** The numbers the website needs to show hints before checkout. */
    public static Map<String, Object> forWeb() {
        Settings s = settings();
        return new Map<String, Object>{
            'localDistricts' => new List<String>(s.localDistricts),
            'homeState'      => s.homeState,
            'defaultMinKg'   => s.defaultMinKg,
            'brandMinKg'     => s.brandMinKg,
            'chargePerKg'    => s.chargePerKg,
            'maxCharge'      => s.maxCharge
        };
    }

    private static String kgText(Decimal kg) {
        Decimal r = kg.setScale(2, RoundingMode.HALF_UP).stripTrailingZeros();
        return r.toPlainString() + ' KG';
    }

    private static String norm(String s) {
        return s == null ? '' : s.trim().replaceAll('\\s+', ' ').toUpperCase();
    }
}
