// Seed / refresh website catalogue products (safe to re-run: upserts on Slug__c)
// PRICES ARE PLACEHOLDERS taken from recent sale rates — edit in the
// Web Products tab before going live.
List<Web_Product__c> products = new List<Web_Product__c>{
    new Web_Product__c(
        Slug__c = 'holiday-250g',
        Name = 'Holiday Makhana — 250g Pouch',
        Brand__c = 'Holiday_250g', Packet_Type__c = '250g',
        Pack_Size_Grams__c = 250, Price_Per_Kg__c = 1200,
        Pack_Label__c = '250g pouch',
        Grade__c = '5 & 5+ Suta · Handpicked',
        Badge__c = 'Flagship',
        Description__c = 'Our flagship handpicked line — large-grade fox nuts, '
            + 'sun-dried and sorted for uniform size and colour.',
        Min_Order_Packets__c = 1, Sort_Order__c = 1, Is_Active__c = true
    ),
    new Web_Product__c(
        Slug__c = 'laddu-gopal-100g',
        Name = 'Laddu Gopal Makhana — 100g Pouch',
        Brand__c = 'Laddu 100g', Packet_Type__c = '100g',
        Pack_Size_Grams__c = 100, Price_Per_Kg__c = 1050,
        Pack_Label__c = '100g pouch',
        Grade__c = '4 & 5 Suta · Mixed',
        Description__c = 'Traditional-grade plain line, popular for everyday '
            + 'consumption, prasad / religious offering use and repacking.',
        Min_Order_Packets__c = 1, Sort_Order__c = 2, Is_Active__c = true
    ),
    new Web_Product__c(
        Slug__c = 'gopala-250g',
        Name = 'Gopala Makhana — 250g Pouch',
        Brand__c = 'Gopala 250g', Packet_Type__c = '250g',
        Pack_Size_Grams__c = 250, Price_Per_Kg__c = 800,
        Pack_Label__c = '250g pouch',
        Grade__c = '3 & 4 Suta · Mixed',
        Badge__c = 'Best Value',
        Description__c = 'Value-grade plain line — smaller, mixed-size fox nuts, '
            + 'handpicked and sun-dried for buyers roasting at scale.',
        Min_Order_Packets__c = 1, Sort_Order__c = 3, Is_Active__c = true
    ),
    new Web_Product__c(
        Slug__c = 'trust-250g',
        Name = 'Trust Makhana — 250g Pouch',
        Brand__c = 'Trust 250g', Packet_Type__c = '250g',
        Pack_Size_Grams__c = 250, Price_Per_Kg__c = 750,
        Pack_Label__c = '250g pouch',
        Grade__c = '3 & 4 Suta · Mixed',
        Description__c = 'Everyday plain makhana at an accessible price point.',
        Min_Order_Packets__c = 1, Sort_Order__c = 4, Is_Active__c = true
    ),
    new Web_Product__c(
        Slug__c = 'holiday-loose-10kg',
        Name = 'Loose Makhana — 10 kg Bulk Bag',
        Brand__c = 'Holiday loose', Packet_Type__c = 'Loose',
        Pack_Size_Grams__c = 10000, Price_Per_Kg__c = 900,
        Pack_Label__c = '10 kg bulk bag',
        Grade__c = 'All grades · 3–6 Suta',
        Badge__c = 'Bulk',
        Description__c = 'Ungraded bulk supply, sold raw for buyers to roast, '
            + 'season or private-label on their end. Plain bag, no branding.',
        Min_Order_Packets__c = 1, Sort_Order__c = 5, Is_Active__c = true
    )
};
upsert products Slug__c;
System.debug('Seeded ' + products.size() + ' web products');
