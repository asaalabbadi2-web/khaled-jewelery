"""The roles, as the owner sees them: what each is called, what it does, what account it takes (MAPPING-UI-1).

CHART-002 made «الربط المحاسبي» the one place an account is chosen for a role --
and the screen knew 17 roles written in its own code, 6 of them no longer asked
for, while the code asks for 60 more (15 Oct 2026). The server now holds the
roles and serves them: the screen draws what is here, and saving a mapping is
checked against it.

Each role: its Arabic name, its group on the screen, the account it takes
(KIND: a cash account, or a weight -- memo -- account), whether the code reads
its linked weight twin too (NEEDS_TWIN), and one sentence on what it does. A
role is required where accounting.mappings.REQUIRED_ROLES asks for it; optional
otherwise; RETIRED when nothing asks for it any more (shown so it can be
removed, never offered for a new mapping).
"""
from __future__ import annotations

from dataclasses import dataclass

DEFAULT = 'افتراضي'
CASH, WEIGHT = 'cash', 'weight'

# The screen's groups, in order.
GROUPS = (
    'الصندوق والضرائب',
    'المبيعات والمشتريات',
    'مخزون الذهب وتكلفته',
    'تسوية الموردين',
    'الأطراف',
    'الموظفون',
    'مجموعات الشجرة (للتقارير)',
    'غير مستعمل',
)

# The operations a role may be mapped for, in the screen's order: the default
# (every operation inherits it) and the operations' own overrides.
OPERATIONS = (DEFAULT, 'بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)',
              'تسوية_مورد', 'سندات')


@dataclass(frozen=True)
class Role:
    key: str
    label: str
    group: str
    purpose: str
    kind: str = CASH
    needs_twin: bool = False
    retired: bool = False
    operations: tuple = ()      # beyond the default, where an override is meaningful


def _r(key, label, group, purpose, **kw):
    return key, Role(key=key, label=label, group=group, purpose=purpose, **kw)


G_CASH, G_TRADE, G_GOLD, G_SUPP, G_PARTY, G_EMP, G_TREE, G_OLD = GROUPS
TRADE_OPS = ('بيع', 'شراء من عميل', 'مرتجع بيع', 'مرتجع شراء', 'شراء', 'مرتجع شراء (مورد)')

ROLES: dict[str, Role] = dict((
    # ── الصندوق والضرائب ──
    _r('cash', 'النقدية (الصندوق الافتراضي)', G_CASH,
       'الصندوق الذي يُقيَّد عليه النقد حين لا تُحدَّد خزينة في الفاتورة.', operations=TRADE_OPS),
    _r('cash_root', 'مجموعة النقدية', G_CASH,
       'أبو حسابات النقدية؛ توأمه الوزني جانبُ النقدية الوزني في القيود.', needs_twin=True),
    _r('vat_payable', 'ضريبة المخرجات (المستحقة)', G_CASH,
       'ضريبة القيمة المضافة على المبيعات.', operations=TRADE_OPS),
    _r('vat_receivable', 'ضريبة المدخلات (المدفوعة)', G_CASH,
       'ضريبة القيمة المضافة على المشتريات والأجور.', operations=TRADE_OPS),
    _r('commission', 'عمولات نقاط البيع', G_CASH,
       'رسوم الدفع الإلكتروني (شبكة، مدى) حين تُحسب عند الفاتورة.', operations=TRADE_OPS),
    _r('commission_vat', 'ضريبة عمولات نقاط البيع', G_CASH,
       'ضريبة القيمة المضافة على رسوم الدفع الإلكتروني.', operations=TRADE_OPS),
    _r('vat_settlement', 'صافي الضريبة المستحقة للهيئة', G_CASH,
       'يُقفل فيه الإقرار الضريبي؛ يُنشأ مرة تحت أبيه إن لم يُربط.'),
    _r('vat_settlement_parent', 'أبو صافي الضريبة المستحقة', G_CASH,
       'المجموعة التي يُنشأ تحتها حساب صافي الضريبة إن لم يُربط.'),
    _r('vat_non_recoverable', 'ضريبة القيمة المضافة غير القابلة للاسترداد', G_CASH,
       'مصروف للضريبة التي لا تُسترد؛ يُنشأ مرة تحت أبيه إن لم يُربط.'),
    _r('vat_non_recoverable_parent', 'أبو الضريبة غير المستردة', G_CASH,
       'المجموعة التي يُنشأ تحتها حساب الضريبة غير المستردة.'),
    # ── المبيعات والمشتريات ──
    _r('revenue', 'الإيرادات (افتراضي المبيعات)', G_TRADE,
       'إيراد البيع حين لا يُميَّز الجديد من الكسر.', operations=TRADE_OPS),
    _r('sales_gold_new', 'مبيعات ذهب جديد', G_TRADE, 'إيراد بيع الذهب الجديد.', operations=TRADE_OPS),
    _r('sales_gold_scrap', 'مبيعات ذهب كسر', G_TRADE, 'إيراد بيع الكسر.', operations=TRADE_OPS),
    _r('sales_returns', 'مردودات المبيعات', G_TRADE, 'يُقيَّد عليه مرتجع البيع.', operations=TRADE_OPS),
    _r('purchases_gold', 'مشتريات الذهب', G_TRADE,
       'ثمن الذهب المشترى حين لا يُميَّز الجديد من الكسر.', operations=TRADE_OPS),
    _r('purchases_gold_new', 'مشتريات ذهب جديد من العملاء', G_TRADE,
       'ثمن الذهب الجديد المشترى من عميل.', operations=TRADE_OPS),
    _r('purchases_gold_scrap', 'مشتريات ذهب كسر', G_TRADE,
       'ثمن الكسر المشترى من عميل أو بتسوية مكتب تسكير.', operations=TRADE_OPS),
    _r('purchase_returns', 'مردودات المشتريات', G_TRADE, 'يُقيَّد عليه مرتجع الشراء.', operations=TRADE_OPS),
    _r('customers', 'العملاء (حساب تجميعي)', G_TRADE,
       'حساب العملاء في المرتجعات، وفي سند عميل لا حساب له («سندات»).', operations=(*TRADE_OPS, 'سندات')),
    _r('suppliers', 'الموردون (حساب تجميعي)', G_TRADE,
       'حساب الموردين في الشراء، وفي سند مورد لا حساب له («سندات»).', operations=(*TRADE_OPS, 'سندات')),
    _r('manufacturing_wage', 'مصروف أجور المصنعية', G_TRADE,
       'تصير الأجور مصروفًا: عند البيع إن رُسملت، وعند الشراء إن لم تُرسمل.', operations=TRADE_OPS),
    _r('manufacturing_wage_inventory', 'مخزون أجور المصنعية', G_TRADE,
       'تُرسمل فيه أجور المصنعية عند الشراء.', needs_twin=True, operations=TRADE_OPS),
    # ── مخزون الذهب وتكلفته ──
    _r('gold_inventory_new', 'مخزون الذهب الجديد (المعروض)', G_GOLD,
       'المخزون المالي للذهب الجديد لكل العيارات؛ توأمه الوزني وزنُ المعروض.', needs_twin=True),
    _r('gold_inventory_scrap', 'مخزون الكسر', G_GOLD,
       'المخزون المالي للكسر لكل العيارات؛ توأمه الوزني وزنُ الكسر.', needs_twin=True),
    _r('gold_cost_of_sales', 'تكلفة مبيعات الذهب', G_GOLD, 'تكلفة الذهب المباع نقدًا.'),
    _r('gold_cost_of_sales_weight', 'تكلفة مبيعات الذهب (وزني)', G_GOLD,
       'الجانب الوزني لتكلفة الذهب المباع.', kind=WEIGHT),
    _r('weight_closing_bridge', 'جسر إقفال الوزن', G_GOLD,
       'يمرّ عليه الوزن حين يُنفَّذ إقفال الوزن شراءً.', needs_twin=True),
    _r('stones_inventory', 'مخزون الأحجار', G_GOLD,
       'قيمة الأحجار المسعَّرة بالقيراط في شراء المورد بالريال؛ تتبع القطعة من 2027.'),
    _r('renewal_stones_revenue', 'إيراد فصوص التجديد', G_GOLD,
       'تدخل فصوص الكسر المجدَّد المعروضَ ذهبًا (تُباع بالقائم)، ويُقيَّد مكسبها هنا وزنًا.', kind=WEIGHT),
    _r('melting_damaged_wage', 'المصنعية التالفة بالتكسير', G_GOLD,
       'يُقيَّد عليه ما تلف من أجور المصنعية المرسملة حين تُكسَّر الحُليّ.'),
    _r('inventory_count_shortage', 'عجز الجرد', G_GOLD, 'يُقيَّد عليه عجز الجرد المعتمد.'),
    _r('inventory_count_surplus', 'زيادة الجرد', G_GOLD, 'يُقيَّد عليه فائض الجرد المعتمد.'),
    _r('karat_diff_revenue', 'خصم السداد بعيار أعلى', G_GOLD,
       'عمولة فرق العيار التي يكسبها المحل، والسداد بذهب صافي.'),
    _r('karat_diff_expense', 'رسوم السداد بعيار أقل', G_GOLD, 'عمولة فرق العيار التي يدفعها المحل.'),
    # ── تسوية الموردين ──
    _r('supplier_settlement_expense', 'خسارة تسوية مورد (نقد)', G_SUPP, 'فرق التسوية النقدي على المحل.',
       operations=('تسوية_مورد',)),
    _r('supplier_settlement_income', 'ربح تسوية مورد (نقد)', G_SUPP, 'فرق التسوية النقدي للمحل.',
       operations=('تسوية_مورد',)),
    _r('supplier_weight_settlement_expense', 'خسارة تسوية مورد (وزن)', G_SUPP, 'فرق التسوية الوزني على المحل.',
       operations=('تسوية_مورد',)),
    _r('supplier_weight_settlement_income', 'ربح تسوية مورد (وزن)', G_SUPP, 'فرق التسوية الوزني للمحل.',
       operations=('تسوية_مورد',)),
    # ── الأطراف ──
    _r('customer_accounts_parent', 'أبو حسابات العملاء', G_PARTY,
       'يُنشأ تحته حساب العميل الجديد بلا فئة؛ تحت توأمه توأمُ العميل.', needs_twin=True),
    _r('supplier_accounts_parent', 'أبو حسابات الموردين', G_PARTY,
       'يُنشأ تحته حساب المورد الجديد بلا فئة؛ تحت توأمه توأمُ المورد.', needs_twin=True),
    _r('office_accounts_parent', 'أبو حسابات مكاتب التسكير', G_PARTY,
       'يُنشأ تحته حساب المكتب الجديد؛ تحت توأمه توأمُ المكتب.', needs_twin=True),
    _r('opening_balance_equity', 'حقوق ملكية الأرصدة الافتتاحية', G_PARTY,
       'مقابل الرصيد الافتتاحي للمورد؛ توأمه مقابل رصيده الذهبي.', needs_twin=True),
    # ── الموظفون ──
    _r('employee_personal_parent', 'أبو حسابات الموظفين الشخصية', G_EMP, 'يُنشأ تحته حساب الموظف الشخصي.'),
    _r('employee_salary_payable_parent', 'أبو ذمم رواتب الموظفين', G_EMP, 'يُنشأ تحته حساب رواتب كل موظف.'),
    _r('employee_commission_payable_parent', 'أبو ذمم عمولات الموظفين', G_EMP, 'يُنشأ تحته حساب عمولات كل موظف.'),
    _r('employee_eos_payable_parent', 'أبو ذمم نهاية الخدمة', G_EMP, 'يُنشأ تحته حساب نهاية خدمة كل موظف.'),
    _r('employee_bonus_payable_parent', 'أبو مكافآت الموظفين المستحقة', G_EMP, 'يُنشأ تحته حساب مكافآت كل موظف.'),
    _r('employee_gold_custody_parent', 'أبو عهدة الذهب للموظفين', G_EMP,
       'تُنشأ تحته عهدة الذهب لكل موظف.', kind=WEIGHT),
    _r('employee_cash_custody_parent', 'أبو العهدة النقدية للموظفين', G_EMP, 'تُنشأ تحته العهدة النقدية لكل موظف.'),
    _r('salary_expense', 'مصروف الرواتب', G_EMP, 'يُقيَّد عليه استحقاق الرواتب.'),
    _r('bonus_expense', 'مصروف المكافآت', G_EMP, 'يُقيَّد عليه اعتماد المكافآت.'),
    # ── مجموعات الشجرة (للتقارير) ──
    _r('assets_root', 'مجموعة الأصول', G_TREE, 'تقرأ التقارير فرعها؛ وفرعُ توأمها حساباتُ الأطراف الوزنية.',
       needs_twin=True),
    _r('liabilities_root', 'مجموعة الخصوم', G_TREE, 'تقرأ التقارير فرعها وفرع توأمها.', needs_twin=True),
    _r('equity_root', 'مجموعة حقوق الملكية', G_TREE, 'تقرأ التقارير فرعها وفرع توأمها.', needs_twin=True),
    _r('revenue_root', 'مجموعة الإيرادات', G_TREE, 'قائمة الدخل وربح الجرام تقرأ فرعها وفرع توأمها.',
       needs_twin=True),
    _r('expenses_root', 'مجموعة المصروفات', G_TREE, 'قائمة الدخل وربح الجرام تقرأ فرعها وفرع توأمها.',
       needs_twin=True),
    _r('operating_revenue_root', 'مجموعة إيرادات النشاط', G_TREE, 'يقرأ ربح الجرام توأمها.', needs_twin=True),
    _r('cost_of_sales_root', 'مجموعة تكلفة المبيعات', G_TREE, 'إجمالي الربح في قائمة الدخل يطرح فرعها.',
       needs_twin=True),
    _r('operating_expenses_root', 'مجموعة المصاريف التشغيلية', G_TREE,
       'تكلفة الذهب تقرأ توأمها مصروفًا وزنيًّا.', needs_twin=True),
    _r('gold_inventory_root', 'مجموعة المخزون', G_TREE, 'مطابقة المخزون والتحليلات تقرأ فرعها.'),
    _r('worked_gold_suppliers_root', 'مجموعة موردي الذهب المشغول', G_TREE, 'تكلفة الذهب تقرأ توأمها مجمّعَ كسر.',
       needs_twin=True),
    _r('valuation_equity', 'فروقات تقييم الذهب', G_TREE, 'يُقفل فيه انتقال تكلفة الذهب إلى المتوسط.'),
    _r('supplier_payables_root', 'مجموعة الموردين (الذمم)', G_TREE, 'رصيد المورد يقرأ ما تحتها.'),
    _r('customer_receivables_root', 'مجموعة العملاء (الذمم)', G_TREE, 'رصيد العميل يقرأ ما تحتها؛ وتوأمها للتكلفة.',
       needs_twin=True),
    # ── غير مستعمل ──
    *(_r(f'weight_profile_{k}', label, G_OLD,
         'لم يعد يطلبه الكود: أُزيل تنفيذ التسكير (ADR-048)؛ المصروف الموسوم يُغلق بسنده.', retired=True, needs_twin=True)
      for k, label in (('cleaning', 'مصروف تنظيف الذهب (قديم)'), ('melting', 'مصروف الصهر (قديم)'),
                       ('logistics', 'مصروف الشحن والتغليف (قديم)'),
                       ('valuation_diff', 'فروقات التقييم (قديم)'))),
    *(_r(f'inventory_{k}k', f'مخزون ذهب عيار {k} (قديم)', G_OLD, 'لم يعد يطلبه الكود: المخزون بدوري الجديد والكسر.',
         retired=True, operations=TRADE_OPS) for k in (18, 21, 22, 24)),
    _r('cost', 'تكلفة البضاعة المباعة (قديم)', G_OLD, 'لم يعد يطلبه الكود: «تكلفة مبيعات الذهب».', retired=True,
       operations=TRADE_OPS),
    _r('profit_loss', 'الأرباح والخسائر (قديم)', G_OLD, 'لم يعد يطلبه الكود.', retired=True, operations=TRADE_OPS),
))

def required_pairs() -> set:
    from accounting.mappings import REQUIRED_ROLES
    return set(REQUIRED_ROLES)


def operations_of(role: Role) -> tuple:
    """The operations shown for *role*: the default first, then its overrides."""
    asked = sorted({op for op, key in required_pairs() if key == role.key and op != DEFAULT},
                   key=OPERATIONS.index)
    extra = [op for op in role.operations if op not in asked and op != DEFAULT]
    return (DEFAULT, *asked, *extra)


def known(operation: str, key: str) -> bool:
    role = ROLES.get(key)
    return role is not None and operation in operations_of(role)
