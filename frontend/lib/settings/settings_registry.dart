/// The settings registry: every setting and every settings screen, where it
/// lives, what it is called and searched by, and what changing it does
/// (settings spec v2 §5; ADR-102). DATA, no logic: the center's index, its
/// search and the guard (test/settings_registry_test.dart) read it.
///
/// A setting's level mirrors the server's (backend/services/settings_policy.py):
/// the guard compares the two. The center owns the Settings keys and this
/// device's keys; every other screen is a link with no logic here (spec v2 §0).
library;

enum SettingsGroup { store, money, operations, system }

enum SettingsSection {
  company,
  goldPrices,
  salesInvoices,
  tax,
  paymentsSafes,
  accounting,
  itemsPieces,
  staffPay,
  usersSecurity,
  thisDevice,
  backupMaintenance,
}

enum SettingScope { company, device }

enum SettingKind { setting, link }

const groupLabels = {
  SettingsGroup.store: 'المتجر',
  SettingsGroup.money: 'المال',
  SettingsGroup.operations: 'التشغيل',
  SettingsGroup.system: 'النظام',
};

class SectionInfo {
  const SectionInfo(this.group, this.label, this.summary);
  final SettingsGroup group;
  final String label;
  final String summary;
}

const sections = <SettingsSection, SectionInfo>{
  SettingsSection.company: SectionInfo(SettingsGroup.store, 'المنشأة', 'البيانات، الترقيم، العملة والأرقام، الفروع'),
  SettingsSection.goldPrices: SectionInfo(SettingsGroup.store, 'الذهب والأسعار',
      'العيار الرئيسي، سعر الشراء والمكتب، التحديث، التسكير'),
  SettingsSection.salesInvoices: SectionInfo(SettingsGroup.store, 'البيع والفواتير',
      'الخصم، الصنف اليدوي، الدفع الجزئي، إلزام الدخول'),
  SettingsSection.tax: SectionInfo(SettingsGroup.store, 'الضريبة', 'ضريبة الفواتير، ضريبة المبيعات، النسبة، الإعفاء'),
  SettingsSection.paymentsSafes: SectionInfo(SettingsGroup.money, 'المدفوعات والخزائن',
      'وسائل الدفع، الخزائن، مسار خزائن الموظفين'),
  SettingsSection.accounting: SectionInfo(SettingsGroup.money, 'المحاسبة والاعتماد',
      'الترحيل، حدود الاعتماد، الأجور، الربط'),
  SettingsSection.itemsPieces: SectionInfo(SettingsGroup.operations, 'الأصناف والقطع',
      'ترميز المخزون، التصنيفات، الأقسام، المقاسات، الملصقات'),
  SettingsSection.staffPay: SectionInfo(SettingsGroup.operations, 'الموظفون والرواتب',
      'سياسة الرواتب، المكافآت، سباق الأداء'),
  SettingsSection.usersSecurity: SectionInfo(SettingsGroup.system, 'المستخدمون والأمان',
      'المستخدمون، الجلسات، الخمول، سجل التدقيق'),
  SettingsSection.thisDevice: SectionInfo(SettingsGroup.system, 'هذا الجهاز',
      'الطباعة، إعدادات الفاتورة، شاشة الدخول'),
  SettingsSection.backupMaintenance: SectionInfo(SettingsGroup.system, 'النسخ والصيانة',
      'النسخ الاحتياطي، الاستيراد، حول النظام، إعادة التهيئة'),
};

/// The old settings screen's tabs, where a center-owned key is set until its
/// section page replaces them (spec v2, phase 7).
abstract final class LegacyTab {
  static const general = 0;
  static const companyInvoices = 1;
  static const payments = 2;
  static const accounting = 3;
  static const printing = 4;
  static const system = 5;
}

/// Said beside a financial (level-3) setting to whoever does not hold its
/// permission (ADR-103).
const needsFinancialPermission = 'يحتاج صلاحية «الإعدادات المالية والمحاسبية»';

class SettingEntry {
  const SettingEntry({
    required this.id,
    required this.section,
    required this.label,
    this.key,
    this.kind = SettingKind.setting,
    this.scope = SettingScope.company,
    this.description = '',
    this.synonyms = const [],
    this.level = 1,
    this.effect,
    this.revertRule,
    this.legacyTab,
    this.screen,
    this.ownerNote,
  });

  final String id;
  final SettingsSection section;
  final String label;

  /// The server's Settings key, or this device's key -- null for a link.
  final String? key;
  final SettingKind kind;
  final SettingScope scope;
  final String description;
  final List<String> synonyms;

  /// 1, 2 or 3 -- the server's level for a company key (settings_policy.py).
  final int level;

  /// What changing it does, and how far it can be undone (level 3: required).
  final String? effect;
  final String? revertRule;

  /// Where it is set today: a tab of the old screen, or a screen id.
  final int? legacyTab;
  final String? screen;

  /// When another screen owns the key: where it is set (spec v2 §0).
  final String? ownerNote;

  SettingsGroup get group => sections[section]!.group;
}

const _forward = 'يسري على ما يُنشأ بعد الحفظ، وما سبقه يبقى كما كان.';

const settingsRegistry = <SettingEntry>[
  // ── المنشأة ───────────────────────────────────────────────────────────
  SettingEntry(id: 'company_name', key: 'company_name', section: SettingsSection.company, label: 'اسم الشركة',
      synonyms: ['المحل', 'المنشأة']),
  SettingEntry(id: 'company_address', key: 'company_address', section: SettingsSection.company, label: 'العنوان'),
  SettingEntry(id: 'company_phone', key: 'company_phone', section: SettingsSection.company, label: 'رقم الهاتف',
      synonyms: ['جوال', 'تلفون']),
  SettingEntry(id: 'company_tax_number', key: 'company_tax_number', section: SettingsSection.company,
      label: 'الرقم الضريبي', synonyms: ['ضريبي', 'VAT'], level: 2),
  SettingEntry(id: 'company_cr_number', key: 'company_cr_number', section: SettingsSection.company,
      label: 'السجل التجاري', synonyms: ['CR']),
  SettingEntry(id: 'show_company_logo', key: 'show_company_logo', section: SettingsSection.company,
      label: 'عرض شعار الشركة على الفواتير', synonyms: ['لوجو', 'شعار']),
  SettingEntry(id: 'invoice_prefix', key: 'invoice_prefix', section: SettingsSection.company,
      label: 'بادئة رقم الفاتورة', synonyms: ['ترقيم', 'رقم الفاتورة', 'الفواتير']),
  SettingEntry(id: 'currency_symbol', key: 'currency_symbol', section: SettingsSection.company, label: 'رمز العملة',
      synonyms: ['ريال', 'العملة']),
  SettingEntry(id: 'decimal_places', key: 'decimal_places', section: SettingsSection.company,
      label: 'عدد المنازل العشرية', synonyms: ['الكسور', 'التقريب']),
  SettingEntry(id: 'date_format', key: 'date_format', section: SettingsSection.company, label: 'تنسيق التاريخ'),
  SettingEntry(id: 'branches', kind: SettingKind.link, section: SettingsSection.company, label: 'الفروع',
      screen: 'branches'),

  // ── الذهب والأسعار ────────────────────────────────────────────────────
  SettingEntry(id: 'main_karat', key: 'main_karat', section: SettingsSection.goldPrices, label: 'العيار الرئيسي',
      synonyms: ['المكافئ', 'عيار المحاسبة', 'الوزن المعادل'], level: 3, legacyTab: LegacyTab.general,
      effect: 'الوزن المعادل في كل قيد يُكتب بالعيار الرئيسي وقت كتابته.',
      revertRule: 'بعد أول قيد بوزن لا يُعاد: تغييره يخلط وحدتين في الدفاتر (القرار D9).'),
  SettingEntry(id: 'buy_price_ratio', key: 'buy_price_ratio', section: SettingsSection.goldPrices,
      label: 'سعر الشراء (نسبة من السوق)', synonyms: ['شراء الكسر', 'سعر الشراء'], level: 2,
      legacyTab: LegacyTab.accounting),
  SettingEntry(id: 'office_main_fees_usd', key: 'office_main_fees_usd', section: SettingsSection.goldPrices,
      label: 'سعر مكتب التسكير: الرسوم الرئيسية', synonyms: ['الديوان', 'المكتب', 'التسكير'], level: 3,
      legacyTab: LegacyTab.accounting, effect: 'يُسعَّر به البيع التالي فورًا، وتبقى الأسعار السابقة بشروطها.',
      revertRule: 'بتغيير جديد؛ كل سعر مختوم بشروطه.'),
  SettingEntry(id: 'office_custom_fees_usd', key: 'office_custom_fees_usd', section: SettingsSection.goldPrices,
      label: 'سعر مكتب التسكير: الرسوم الخاصة', synonyms: ['الديوان', 'المكتب'], level: 3,
      legacyTab: LegacyTab.accounting, effect: 'يُسعَّر به البيع التالي فورًا، وتبقى الأسعار السابقة بشروطها.',
      revertRule: 'بتغيير جديد؛ كل سعر مختوم بشروطه.'),
  SettingEntry(id: 'office_discount_21', key: 'office_discount_21', section: SettingsSection.goldPrices,
      label: 'سعر مكتب التسكير: خصم عيار 21', synonyms: ['الديوان', 'المكتب'], level: 3,
      legacyTab: LegacyTab.accounting, effect: 'يُسعَّر به البيع التالي فورًا، وتبقى الأسعار السابقة بشروطها.',
      revertRule: 'بتغيير جديد؛ كل سعر مختوم بشروطه.'),
  SettingEntry(id: 'office_discount_18', key: 'office_discount_18', section: SettingsSection.goldPrices,
      label: 'سعر مكتب التسكير: خصم عيار 18', synonyms: ['الديوان', 'المكتب'], level: 3,
      legacyTab: LegacyTab.accounting, effect: 'يُسعَّر به البيع التالي فورًا، وتبقى الأسعار السابقة بشروطها.',
      revertRule: 'بتغيير جديد؛ كل سعر مختوم بشروطه.'),
  SettingEntry(id: 'gold_price_auto_update_enabled', key: 'gold_price_auto_update_enabled',
      section: SettingsSection.goldPrices, label: 'تحديث سعر الذهب تلقائيًا', synonyms: ['السعر', 'تحديث'],
      legacyTab: LegacyTab.system),
  SettingEntry(id: 'gold_price_auto_update_interval_seconds', key: 'gold_price_auto_update_interval_seconds',
      section: SettingsSection.goldPrices, label: 'فترة تحديث السعر', synonyms: ['كل 15 ثانية'],
      legacyTab: LegacyTab.system),
  SettingEntry(id: 'gold_price_manual', kind: SettingKind.link, section: SettingsSection.goldPrices,
      label: 'سعر الذهب اليدوي', synonyms: ['السعر'], screen: 'gold_price_manual'),
  SettingEntry(id: 'weight_closing', kind: SettingKind.link, section: SettingsSection.goldPrices,
      label: 'إعدادات التسكير', synonyms: ['التسكير الوزني', 'الحجز'], screen: 'weight_closing'),

  // ── البيع والفواتير ───────────────────────────────────────────────────
  SettingEntry(id: 'allow_discount', key: 'allow_discount', section: SettingsSection.salesInvoices,
      label: 'السماح بالخصم على الفواتير', synonyms: ['خصم'], level: 2),
  SettingEntry(id: 'default_discount_rate', key: 'default_discount_rate', section: SettingsSection.salesInvoices,
      label: 'نسبة الخصم الافتراضية', synonyms: ['خصم'], level: 2),
  SettingEntry(id: 'allow_manual_invoice_items', key: 'allow_manual_invoice_items',
      section: SettingsSection.salesInvoices, label: 'الصنف اليدوي في الفاتورة', level: 2,
      description: 'يظهر في فاتورة البيع زر لإدخال صنف ببيانات مخصصة: اسم ووزن وعيار.'),
  SettingEntry(id: 'allow_partial_invoice_payments', key: 'allow_partial_invoice_payments',
      section: SettingsSection.salesInvoices, label: 'الدفع الجزئي (بيع آجل)', synonyms: ['آجل', 'ذمم', 'الباقي'],
      level: 2,
      description: 'مفعّلًا تُحفظ فاتورة البيع بمدفوع أقل من إجماليها أو بلا دفعات بعد تأكيد؛ معطّلًا يلزم أن تساوي الدفعات إجماليها.'),
  SettingEntry(id: 'require_auth_for_invoice_create', key: 'require_auth_for_invoice_create',
      section: SettingsSection.salesInvoices, label: 'إلزام تسجيل الدخول لإنشاء الفواتير', level: 2,
      description: 'لا تُنشأ فاتورة بلا تسجيل دخول، فيُعرف منشئها وتُحسب مكافأته.'),

  // ── الضريبة ───────────────────────────────────────────────────────────
  SettingEntry(id: 'tax_enabled', key: 'tax_enabled', section: SettingsSection.tax,
      label: 'ضريبة الفواتير (المفتاح العام)', synonyms: ['VAT', 'القيمة المضافة', 'ضريبة'], level: 3,
      description: 'يشمل البيع والشراء والأحجار وضريبة عمولات وسائل الدفع',
      effect: 'يسري على الفواتير التي تُحفظ بعده.',
      revertRule: 'بتغيير جديد؛ بلا تاريخ، فلا يصلح فاتورة حُفظت بينهما.'),
  SettingEntry(id: 'sales_vat_enabled', key: 'sales_vat_enabled', section: SettingsSection.tax,
      label: 'ضريبة المبيعات', synonyms: ['VAT', 'القيمة المضافة', 'فاتورة بدون ضريبة'], level: 3,
      description: 'للبيع وحده، بتاريخ؛ لا تمسّ ضريبة المشتريات',
      effect: 'تُكتب فترة من اليوم في سياسة الضريبة.',
      revertRule: 'فترة جديدة؛ ما بيع بين الفترتين يبقى كما بيع.'),
  SettingEntry(id: 'tax_rate', key: 'tax_rate', section: SettingsSection.tax, label: 'نسبة الضريبة',
      synonyms: ['VAT', '15'], level: 3, effect: _forward,
      revertRule: 'بتغيير جديد؛ لا يصلح فاتورة حُفظت بينهما.'),
  SettingEntry(id: 'vat_exempt_karats', key: 'vat_exempt_karats', section: SettingsSection.tax,
      label: 'العيارات المعفاة من الضريبة', synonyms: ['24', 'إعفاء'], level: 3,
      effect: _forward, revertRule: 'بتغيير جديد.'),

  // ── المدفوعات والخزائن ────────────────────────────────────────────────
  SettingEntry(id: 'employee_cash_safes_enabled', key: 'employee_cash_safes_enabled',
      section: SettingsSection.paymentsSafes, label: 'خزائن الموظفين للنقد', synonyms: ['خزينة الموظف', 'الصندوق'],
      level: 3, legacyTab: LegacyTab.accounting, effect: _forward,
      revertRule: 'للمستقبل؛ الحركات على الخزينة السابقة تبقى عليها.'),
  SettingEntry(id: 'employee_gold_safes_enabled', key: 'employee_gold_safes_enabled',
      section: SettingsSection.paymentsSafes, label: 'خزائن الموظفين للذهب (الكسر)', synonyms: ['خزينة الموظف', 'الكسر'],
      level: 3, legacyTab: LegacyTab.accounting, effect: _forward,
      revertRule: 'للمستقبل؛ الحركات على الخزينة السابقة تبقى عليها.'),
  SettingEntry(id: 'main_cash_safe_box_id', key: 'main_cash_safe_box_id', section: SettingsSection.paymentsSafes,
      label: 'الصندوق النقدي الرئيسي', synonyms: ['الخزينة'], level: 3, legacyTab: LegacyTab.accounting,
      effect: _forward, revertRule: 'للمستقبل؛ الحركات على الخزينة السابقة تبقى عليها.'),
  SettingEntry(id: 'sale_gold_safe_box_id', key: 'sale_gold_safe_box_id', section: SettingsSection.paymentsSafes,
      label: 'خزينة الذهب المعروض للبيع', synonyms: ['الخزينة'], level: 3, legacyTab: LegacyTab.accounting,
      effect: _forward, revertRule: 'للمستقبل؛ الحركات على الخزينة السابقة تبقى عليها.'),
  SettingEntry(id: 'main_scrap_gold_safe_box_id', key: 'main_scrap_gold_safe_box_id',
      section: SettingsSection.paymentsSafes, label: 'خزينة الكسر الرئيسية', synonyms: ['الكسر', 'الخزينة'], level: 3,
      legacyTab: LegacyTab.accounting, effect: _forward,
      revertRule: 'للمستقبل؛ الحركات على الخزينة السابقة تبقى عليها.'),
  SettingEntry(id: 'payment_methods', kind: SettingKind.link, section: SettingsSection.paymentsSafes,
      label: 'وسائل الدفع', synonyms: ['مدى', 'تمارا', 'تابي', 'عمولة', 'خطط'], screen: 'payment_methods'),
  SettingEntry(id: 'safe_boxes', kind: SettingKind.link, section: SettingsSection.paymentsSafes, label: 'الخزائن',
      synonyms: ['الصندوق', 'البنك'], screen: 'safe_boxes'),

  // ── المحاسبة والاعتماد ────────────────────────────────────────────────
  SettingEntry(id: 'voucher_auto_post', key: 'voucher_auto_post', section: SettingsSection.accounting,
      label: 'ترحيل السندات تلقائيًا عند الحفظ', synonyms: ['ترحيل', 'اعتماد', 'السندات'], level: 3,
      legacyTab: LegacyTab.accounting, description: 'يقرّر اليوم اعتماد سندات مدير النظام عند إنشائها (القرار D2)',
      effect: _forward, revertRule: 'للمستقبل؛ ما رُحّل يبقى مرحّلًا.'),
  SettingEntry(id: 'accountant_approval_limit_cash', key: 'accountant_approval_limit_cash',
      section: SettingsSection.accounting, label: 'حدّ اعتماد المحاسب نقدًا', synonyms: ['اعتماد', 'المحاسب'],
      level: 2, legacyTab: LegacyTab.accounting),
  SettingEntry(id: 'accountant_approval_limit_gold_grams', key: 'accountant_approval_limit_gold_grams',
      section: SettingsSection.accounting, label: 'حدّ اعتماد المحاسب وزنًا', synonyms: ['اعتماد', 'المحاسب'],
      level: 2, legacyTab: LegacyTab.accounting),
  SettingEntry(id: 'gold_settlement_tolerance_grams', key: 'gold_settlement_tolerance_grams',
      section: SettingsSection.accounting, label: 'هامش فرق سداد الذهب', synonyms: ['هامش', 'فرق'], level: 2,
      legacyTab: LegacyTab.accounting),
  SettingEntry(id: 'manufacturing_wage_mode', key: 'manufacturing_wage_mode', section: SettingsSection.accounting,
      label: 'معالجة أجور التصنيع', synonyms: ['الأجور', 'رسملة', 'مصروف'], level: 3,
      legacyTab: LegacyTab.companyInvoices,
      effect: 'الفواتير المحفوظة تبقى على معالجتها، والتغيير يسري على ما يُنشأ بعد الحفظ.',
      revertRule: 'للمستقبل؛ القطع الموجودة لا تتطابق أجورها بعد التغيير.'),
  SettingEntry(id: 'posting', kind: SettingKind.link, section: SettingsSection.accounting, label: 'اعتماد الترحيل',
      synonyms: ['ترحيل القيود', 'ترحيل الفواتير', 'إلغاء الترحيل'], screen: 'posting',
      description: 'إعدادات الترحيل الأربعة تُضبط هنا حتى القرار D12'),
  SettingEntry(id: 'supplier_settlement_policy', kind: SettingKind.link, section: SettingsSection.accounting,
      label: 'حدود تسوية فروقات الموردين', synonyms: ['الموردين', 'تسوية'], screen: 'supplier_settlement_policy'),
  SettingEntry(id: 'accounting_mapping', kind: SettingKind.link, section: SettingsSection.accounting,
      label: 'الربط المحاسبي', synonyms: ['الحسابات', 'الأدوار'], screen: 'accounting_mapping'),
  SettingEntry(id: 'accounts', kind: SettingKind.link, section: SettingsSection.accounting, label: 'دليل الحسابات',
      synonyms: ['الحسابات'], screen: 'accounts'),
  SettingEntry(id: 'period_lock', kind: SettingKind.link, section: SettingsSection.accounting, label: 'إقفال الفترات',
      synonyms: ['إقفال', 'قفل الشهر'], screen: 'period_lock'),

  // ── الأصناف والقطع ────────────────────────────────────────────────────
  SettingEntry(id: 'coding_on', key: 'coding_on', section: SettingsSection.itemsPieces,
      label: 'ترميز المخزون الموجود قطعًا', synonyms: ['الترميز', 'القطع', 'الجرد'], level: 2,
      legacyTab: LegacyTab.companyInvoices),
  SettingEntry(id: 'categories', kind: SettingKind.link, section: SettingsSection.itemsPieces, label: 'التصنيفات',
      synonyms: ['الأصناف'], screen: 'categories'),
  SettingEntry(id: 'item_sections', kind: SettingKind.link, section: SettingsSection.itemsPieces, label: 'الأقسام',
      screen: 'item_sections'),
  SettingEntry(id: 'size_systems', kind: SettingKind.link, section: SettingsSection.itemsPieces,
      label: 'أنظمة المقاسات', synonyms: ['المقاس'], screen: 'size_systems'),
  SettingEntry(id: 'label_printers', kind: SettingKind.link, section: SettingsSection.itemsPieces,
      label: 'طابعات الملصقات', synonyms: ['ملصق', 'طابعة', 'باركود'], screen: 'label_printers'),

  // ── الموظفون والرواتب ─────────────────────────────────────────────────
  SettingEntry(id: 'payroll_policy', kind: SettingKind.link, section: SettingsSection.staffPay,
      label: 'سياسة الرواتب', synonyms: ['الرواتب', 'نهاية الخدمة'], screen: 'payroll_policy'),
  SettingEntry(id: 'bonus_rules', kind: SettingKind.link, section: SettingsSection.staffPay, label: 'قواعد المكافآت',
      synonyms: ['المكافآت', 'العمولة'], screen: 'bonus_rules'),
  SettingEntry(id: 'sales_race', kind: SettingKind.link, section: SettingsSection.staffPay, label: 'سباق الأداء',
      synonyms: ['الهدف', 'أهداف المبيعات'], screen: 'sales_race'),

  // ── المستخدمون والأمان ────────────────────────────────────────────────
  SettingEntry(id: 'idle_timeout_enabled', key: 'idle_timeout_enabled', section: SettingsSection.usersSecurity,
      label: 'تسجيل الخروج عند عدم النشاط', synonyms: ['الخمول', 'الجلسة'], level: 2, legacyTab: LegacyTab.system),
  SettingEntry(id: 'idle_timeout_minutes', key: 'idle_timeout_minutes', section: SettingsSection.usersSecurity,
      label: 'مدة عدم النشاط', synonyms: ['الخمول', 'الجلسة'], level: 2, legacyTab: LegacyTab.system),
  SettingEntry(id: 'users', kind: SettingKind.link, section: SettingsSection.usersSecurity,
      label: 'المستخدمون والصلاحيات', synonyms: ['صلاحية', 'دخول'], screen: 'users'),
  SettingEntry(id: 'sessions', kind: SettingKind.link, section: SettingsSection.usersSecurity, label: 'الجلسات',
      screen: 'sessions'),
  SettingEntry(id: 'audit_log', kind: SettingKind.link, section: SettingsSection.usersSecurity, label: 'سجل التدقيق',
      synonyms: ['من غيّر'], screen: 'audit_log'),

  // ── هذا الجهاز ────────────────────────────────────────────────────────
  SettingEntry(id: 'print_in_color', key: 'print_in_color', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'طباعة ملونة', synonyms: ['أبيض وأسود', 'الطباعة'],
      legacyTab: LegacyTab.printing),
  SettingEntry(id: 'invoice_paper', key: 'invoice_ui_settings_v1.global.paper_size', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'مقاس ورق الفواتير',
      synonyms: ['ورق', 'حراري', '80', 'A4', 'A5', 'مقاس'], legacyTab: LegacyTab.printing),
  SettingEntry(id: 'voucher_paper', key: 'printer_paper_size_v1', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'مقاس ورق السندات',
      synonyms: ['ورق', 'حراري', '80', '58', 'A4', 'مقاس'], legacyTab: LegacyTab.printing),
  SettingEntry(id: 'printer_preferred', key: 'printer_preferred_name_v1', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'الطابعة المفضلة', synonyms: ['طابعة'], legacyTab: LegacyTab.printing),
  SettingEntry(id: 'printer_auto_connect', key: 'printer_auto_connect_v1', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'الاتصال التلقائي بالطابعة', synonyms: ['طابعة'],
      legacyTab: LegacyTab.printing),
  SettingEntry(id: 'printer_show_preview', key: 'printer_show_preview_v1', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'المعاينة قبل الطباعة', synonyms: ['طباعة'],
      legacyTab: LegacyTab.printing),
  SettingEntry(id: 'printer_auto_cut', key: 'printer_auto_cut_v1', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'القطع التلقائي بعد الطباعة', synonyms: ['حراري', 'قص'],
      legacyTab: LegacyTab.printing),
  SettingEntry(id: 'login_gold_ticker', key: 'ui_show_gold_price_ticker_on_login_v1', scope: SettingScope.device,
      section: SettingsSection.thisDevice, label: 'شريط السعر في شاشة الدخول', synonyms: ['السعر', 'الدخول'],
      legacyTab: LegacyTab.system),

  // ── النسخ والصيانة ────────────────────────────────────────────────────
  SettingEntry(id: 'backup', kind: SettingKind.link, section: SettingsSection.backupMaintenance,
      label: 'النسخ الاحتياطي والاستعادة', synonyms: ['نسخة', 'استعادة'], screen: 'backup'),
  SettingEntry(id: 'import_excel', kind: SettingKind.link, section: SettingsSection.backupMaintenance,
      label: 'استيراد Excel', synonyms: ['استيراد'], screen: 'import_excel'),
  SettingEntry(id: 'about', kind: SettingKind.link, section: SettingsSection.backupMaintenance, label: 'حول النظام',
      synonyms: ['الإصدار'], legacyTab: LegacyTab.system),
  SettingEntry(id: 'system_reset', kind: SettingKind.link, section: SettingsSection.backupMaintenance,
      label: 'إعادة تهيئة النظام', synonyms: ['مسح', 'تصفير'], screen: 'system_reset',
      description: 'منطقة الخطر: لمدير النظام وحده'),
];

List<SettingEntry> entriesOf(SettingsSection section) =>
    [for (final e in settingsRegistry) if (e.section == section) e];
