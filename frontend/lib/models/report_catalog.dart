import 'package:flutter/material.dart';
import 'report_models.dart';

/// كتالوج التقارير الافتراضي للنظام
class ReportCatalog {
  static List<ReportCategory> buildDefaultCatalog() {
    return [
      ReportCategory(
        id: 'financial',
        icon: Icons.account_balance_wallet,
        accentColor: const Color(0xFF1565C0),
        nameAr: 'التقارير المالية',
        nameEn: 'Financial Reports',
        reports: const [
          ReportDescriptor(
            id: 'admin_dashboard',
            icon: Icons.dashboard,
            titleAr: 'لوحة تحكم المدير',
            titleEn: 'Admin Dashboard',
            descriptionAr:
                'مؤشرات سريعة، مخططات، وتنبيهات من واقع دفتر الخزينة وإغلاق الورديات.',
            descriptionEn:
                'Quick KPIs, charts, and alerts from the ledger and shift closings.',
            route: 'admin_dashboard',
            type: ReportType.financial,
            requiresFilters: false,
          ),
          ReportDescriptor(
            id: 'weight_position',
            icon: Icons.balance,
            titleAr: 'مركز التسكير',
            titleEn: 'Weight Closing Position',
            descriptionAr:
                'ريالات المبيعات التي تنتظر أن تعود ذهبًا وقيمتها بسعر شرائك، والربح الوزني بطبقاته الخمس.',
            descriptionEn:
                'Sales riyals waiting to become gold again, their worth at your purchase price, and the weight profit in five layers.',
            route: 'weight_position',
            type: ReportType.financial,
            requiresFilters: false,
          ),
          ReportDescriptor(
            id: 'reconciliation_findings',
            icon: Icons.fact_check,
            titleAr: 'نتائج الفحص الليلي',
            titleEn: 'Nightly Check Findings',
            descriptionAr:
                'ما وجدته فحوص الدفاتر الليلية ومهام التسوية: قيود خاطئة، تسويات متأخرة، وفروق الخزائن — الخطر القائم أولًا.',
            descriptionEn:
                'What the nightly book checks and settlement jobs found — standing risk first.',
            route: 'reconciliation_findings',
            type: ReportType.financial,
            requiresFilters: false,
          ),
          ReportDescriptor(
            id: 'vat_returns',
            icon: Icons.assignment_turned_in_outlined,
            titleAr: 'إقرارات ضريبة القيمة المضافة',
            titleEn: 'VAT Returns',
            descriptionAr:
                'إقرار الفترة: ضريبة المخرجات مقابل المدخلات، والصافي المستحق للهيئة أو لكم — قيد واحد في آخر يوم من الفترة.',
            descriptionEn:
                "A period's return: output VAT against input VAT, the net owed or due back -- one entry at the period's end.",
            route: 'vat_returns',
            type: ReportType.financial,
            requiresFilters: false,
          ),
          ReportDescriptor(
            id: 'analytics_dashboard',
            icon: Icons.insights,
            titleAr: 'لوحة التحليل الوزني',
            titleEn: 'Weighted Analytics Dashboard',
            descriptionAr:
                'تحليل تفاعلي للوزن المكافئ (بالعيار الرئيسي) والتدفقات النقدية حسب الفروع أو نوع العملية أو الموظف.',
            descriptionEn:
                'Interactive analysis of main-karat equivalent weight and cash flows by office, transaction type, or employee.',
            route: 'analytics_dashboard',
            type: ReportType.financial,
            requiresFilters: true,
          ),
          ReportDescriptor(
            id: 'income_statement',
            icon: Icons.trending_up,
            titleAr: 'قائمة الدخل',
            titleEn: 'Income Statement',
            descriptionAr:
                'تحليل الإيرادات والمصروفات والربح الصافي حسب الفترة.',
            descriptionEn:
                'Analyze revenues, expenses, and net profit by period.',
            route: 'income_statement',
            type: ReportType.financial,
            keywords: ['أرباح', 'خسائر', 'ميزانية'],
            requiresFilters: true,
          ),
          ReportDescriptor(
            id: 'balance_sheet',
            icon: Icons.account_balance,
            titleAr: 'الميزانية العمومية',
            titleEn: 'Balance Sheet',
            descriptionAr:
                'ما للمحل وما عليه في يوم، بالريال وبالجرام، متوازنة من الدفاتر.',
            descriptionEn:
                'What the shop owns and owes on a day, in riyals and grams.',
            route: 'balance_sheet',
            type: ReportType.financial,
            requiresFilters: false,
            keywords: ['ميزانية', 'مركز مالي', 'أصول', 'خصوم'],
          ),
          ReportDescriptor(
            id: 'cash_flow',
            icon: Icons.swap_vert_circle,
            titleAr: 'التدفقات النقدية',
            titleEn: 'Cash Flow',
            descriptionAr:
                'من أين جاءت الريالات وأين ذهبت: التشغيل والاستثمار والتمويل، مغلقة على رصيد النقد.',
            descriptionEn:
                'Where the riyals came from and went: operating, investing, financing.',
            route: 'cash_flow',
            type: ReportType.financial,
            keywords: ['تدفق', 'نقد', 'صندوق', 'بنك'],
          ),
          ReportDescriptor(
            id: 'trial_balance',
            icon: Icons.balance,
            titleAr: 'ميزان المراجعة',
            titleEn: 'Trial Balance',
            descriptionAr: 'مراجعة الأرصدة الإجمالية حسب الحساب والعيار.',
            descriptionEn: 'Review total balances by account and karat.',
            route: 'trial_balance',
            type: ReportType.accounting,
            requiresFilters: true,
          ),
          ReportDescriptor(
            id: 'supplier_aging',
            icon: Icons.hourglass_bottom,
            titleAr: 'أعمار ديون الموردين',
            titleEn: 'Supplier Aging',
            descriptionAr:
                'ما على المحل لكل مورد بعمر كل بند، بالريال أو بالجرام، من حسابه الجاري ومطابقًا لدفتره.',
            descriptionEn:
                'What the shop owes each supplier by age, in riyals or grams, from its running account.',
            route: 'supplier_aging',
            type: ReportType.accounting,
            keywords: ['مورد', 'أعمار', 'ذمم', 'دائنون'],
          ),
        ],
      ),
      ReportCategory(
        id: 'sales',
        icon: Icons.point_of_sale,
        accentColor: const Color(0xFF2E7D32),
        nameAr: 'تقارير المبيعات والمشتريات',
        nameEn: 'Sales & Purchases Reports',
        reports: const [
          ReportDescriptor(
            id: 'sales_analysis',
            icon: Icons.insights,
            titleAr: 'تحليل المبيعات',
            titleEn: 'Sales Analysis',
            descriptionAr:
                'المبيعات حسب الموظف أو العميل أو اليوم أو الشهر أو التصنيف أو الصنف أو العيار أو نوع الذهب، مطابقة للدفاتر، مع المقارنة بالفترة السابقة.',
            descriptionEn:
                'Sales by employee, customer, day, month, category, item, karat or gold type, agreeing with the books.',
            route: 'sales_analysis',
            type: ReportType.sales,
            keywords: [
              'مبيعات',
              'موظف',
              'عميل',
              'مقارنة',
              'ملخص',
              'تصنيف',
              'صنف',
              'عيار',
              'كسر',
            ],
          ),
          ReportDescriptor(
            id: 'purchases_analysis',
            icon: Icons.shopping_basket,
            titleAr: 'تحليل المشتريات',
            titleEn: 'Purchases Analysis',
            descriptionAr:
                'المشتريات من العملاء والمكاتب والموردين، بريال الدفاتر وبالجرام، حسب النوع أو الطرف أو الموظف أو اليوم أو الشهر أو العيار، مطابقة للدفاتر.',
            descriptionEn:
                'Purchases from customers, offices and suppliers, in the books\' riyals and grams, agreeing with the books.',
            route: 'purchases_analysis',
            type: ReportType.sales,
            keywords: ['مشتريات', 'كسر', 'مورد', 'مكتب', 'شراء'],
          ),
        ],
      ),
      ReportCategory(
        id: 'inventory',
        icon: Icons.warehouse,
        accentColor: const Color(0xFFFF8F00),
        nameAr: 'تقارير المخزون',
        nameEn: 'Inventory Reports',
        reports: const [
          ReportDescriptor(
            id: 'category_weight_audit',
            icon: Icons.category,
            titleAr: 'جرد الأوزان حسب التصنيف',
            titleEn: 'Category Weight Audit',
            descriptionAr:
                'عرض أرصدة الأوزان بالعيار الرئيسي حسب (الموقع/الخزنة) والتصنيف، مع سجل الحركة.',
            descriptionEn:
                'View main-karat weight balances by (location/safe box) and category, with a movement log.',
            route: 'category_weight_audit',
            type: ReportType.inventory,
            requiresFilters: false,
          ),
        ],
      ),
      ReportCategory(
        id: 'gold',
        icon: Icons.currency_bitcoin,
        accentColor: const Color(0xFFFFD700),
        nameAr: 'تقارير الذهب',
        nameEn: 'Gold Reports',
        reports: const [
          ReportDescriptor(
            id: 'customer_balances',
            icon: Icons.people_alt_outlined,
            titleAr: 'أرصدة العملاء (ريال وذهب)',
            titleEn: 'Customer Balances',
            descriptionAr:
                'ما على كل عميل وما له في يوم، بالريال والجرام، من دفتره.',
            descriptionEn:
                'What each customer owes or is owed on a day, in riyals and grams, from the ledger.',
            route: 'customer_balances',
            type: ReportType.gold,
            keywords: ['عميل', 'رصيد', 'ذهب', 'ذمم'],
          ),
          ReportDescriptor(
            id: 'gold_price_history',
            icon: Icons.timeline,
            titleAr: 'تاريخ أسعار الذهب',
            titleEn: 'Gold Price History',
            descriptionAr: 'رسم بياني لأسعار الذهب اليومية مع المقارنات.',
            descriptionEn: 'Historical daily gold price with comparisons.',
            route: 'gold_price_history',
            type: ReportType.gold,
            requiresFilters: true,
          ),
          ReportDescriptor(
            id: 'gold_by_place',
            icon: Icons.scale,
            titleAr: 'الذهب حسب مكانه',
            titleEn: 'Gold by Place',
            descriptionAr:
                'أين ذهب المحل في يوم: كل خزينة ومخزن وعهدة ومكتب، بجرامات كل عيار وبالعيار الرئيسي، مطابقًا لأصول الميزانية بالوزن.',
            descriptionEn:
                'Where the shop\'s gold is on a day, place by place, agreeing with the balance sheet in grams.',
            route: 'gold_by_place',
            type: ReportType.gold,
            keywords: ['ذهب', 'مركز', 'خزينة', 'مخزون', 'عهدة', 'مكان'],
          ),
          ReportDescriptor(
            id: 'gold_safe_boxes_inventory',
            icon: Icons.badge_outlined,
            titleAr: 'جرد صناديق الذهب (عهد الموظفين)',
            titleEn: 'Gold Safe Boxes Inventory (Employees)',
            descriptionAr: 'عرض جرد صناديق الذهب مع إجماليات سريعة.',
            descriptionEn: 'Gold safe boxes inventory with quick totals.',
            route: 'safe_boxes_screen',
            type: ReportType.gold,
            requiresFilters: true,
          ),
          ReportDescriptor(
            id: 'safe_gold_reconciliation',
            icon: Icons.compare_arrows,
            titleAr: 'ميزان مراجعة الأوزان (خزنة ↔ حساب)',
            titleEn: 'Gold Safes against the Books',
            descriptionAr:
                'دفتر كل خزينة ذهب مقابل حسابها في الدفاتر، عيارًا عيارًا، في يوم — حساب الفحص الليلي نفسه.',
            descriptionEn:
                'Each gold safe\'s statement against its account in the books, karat by karat, on a day.',
            route: 'safe_gold_reconciliation',
            type: ReportType.gold,
            keywords: ['خزينة', 'ذهب', 'مطابقة', 'فرق', 'ميزان'],
          ),
        ],
      ),
      ReportCategory(
        id: 'payroll',
        icon: Icons.people_alt,
        accentColor: const Color(0xFF512DA8),
        nameAr: 'تقارير الموارد البشرية',
        nameEn: 'HR Reports',
        reports: const [
          ReportDescriptor(
            id: 'payroll_monthly',
            icon: Icons.insert_chart,
            titleAr: 'التقرير الشهري للرواتب',
            titleEn: 'Monthly Payroll Report',
            descriptionAr: 'رواتب الموظفين مع الخصومات والإضافات لكل شهر.',
            descriptionEn: 'Employees payroll with deductions and additions.',
            route: 'payroll_report',
            type: ReportType.payroll,
          ),
          ReportDescriptor(
            id: 'bonus_payables',
            icon: Icons.card_giftcard,
            titleAr: 'المكافآت المستحقة',
            titleEn: 'Bonus Payables',
            descriptionAr:
                'المكافآت المعتمدة غير المصروفة لكل موظف، ومطابقتها برصيد حساب المكافآت المستحقة.',
            descriptionEn:
                'Approved unpaid bonuses per employee, reconciled to the payable account.',
            route: 'bonus_payables',
            type: ReportType.payroll,
            requiresFilters: false,
          ),
        ],
      ),
      ReportCategory(
        id: 'accounting',
        icon: Icons.receipt_long,
        accentColor: const Color(0xFF00897B),
        nameAr: 'دفاتر المحاسبة',
        nameEn: 'Accounting Ledgers',
        reports: const [
          ReportDescriptor(
            id: 'general_ledger',
            icon: Icons.menu_book,
            titleAr: 'دفتر الأستاذ العام',
            titleEn: 'General Ledger',
            descriptionAr: 'كافة الحركات المحاسبية مع الرصيد التراكمي.',
            descriptionEn: 'All journal entries with running balances.',
            route: 'general_ledger',
            type: ReportType.accounting,
          ),
          ReportDescriptor(
            id: 'account_statement',
            icon: Icons.account_tree,
            titleAr: 'كشف حساب تفصيلي',
            titleEn: 'Detailed Account Statement',
            descriptionAr: 'عرض تدفقات الحساب المختار حسب العيار والنقد.',
            descriptionEn:
                'Display flows of selected account by karat and cash.',
            route: 'account_statement',
            type: ReportType.accounting,
          ),
        ],
      ),
    ];
  }
}
