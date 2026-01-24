# إعدادات النظام
MAIN_KARAT = 21  # العيار الرئيسي للذهب


# ╔════════════════════════════════════════════════════════════╗
# ║  إعدادات الأمان (Feature Flags)                           ║
# ╚════════════════════════════════════════════════════════════╝
# تفعيل رفض إنشاء الفواتير بدون توكن.
# 0/false: يسمح (للتوافق مع عملاء قدامى)
# 1/true : يرفض أي POST /api/invoices بدون Authorization
import os


def _env_bool(name: str, default: bool = False) -> bool:
	value = os.getenv(name)
	if value is None:
		return default
	return str(value).strip().lower() in ('1', 'true', 'yes', 'y', 'on')


REQUIRE_AUTH_FOR_INVOICE_CREATE = _env_bool('REQUIRE_AUTH_FOR_INVOICE_CREATE', default=False)


# ╔════════════════════════════════════════════════════════════╗
# ║  JWT Authentication Settings                               ║
# ╚════════════════════════════════════════════════════════════╝
#
# ملاحظة: لا نخزن الأسرار داخل الكود. استخدم متغيرات البيئة:
# - JWT_SECRET_KEY
# - JWT_ALGORITHM (اختياري)
# - JWT_ACCESS_TOKEN_EXP_MINUTES (اختياري)
# - JWT_REFRESH_TOKEN_EXP_DAYS (اختياري)


def _env_int(name: str, default: int) -> int:
	value = os.getenv(name)
	if value is None:
		return default
	try:
		return int(str(value).strip())
	except (TypeError, ValueError):
		return default


JWT_SECRET_KEY = os.getenv('JWT_SECRET_KEY', '').strip()
JWT_ALGORITHM = os.getenv('JWT_ALGORITHM', 'HS256').strip() or 'HS256'

# Short-lived access token improves security. Keep it small and refresh silently.
JWT_ACCESS_TOKEN_EXP_MINUTES = _env_int('JWT_ACCESS_TOKEN_EXP_MINUTES', default=60 * 24)

# Auto-logout on inactivity (server-side).
# 0 disables idle-timeout enforcement.
JWT_IDLE_TIMEOUT_MINUTES = _env_int('JWT_IDLE_TIMEOUT_MINUTES', default=30)

# Long-lived refresh token (server-side revocable)
JWT_REFRESH_TOKEN_EXP_DAYS = _env_int('JWT_REFRESH_TOKEN_EXP_DAYS', default=14)

# في بيئات التطوير فقط (عند عدم تعيين JWT_SECRET_KEY) نستخدم fallback.
# في الإنتاج يجب ضبط JWT_SECRET_KEY وإلا ستفشل المصادقة.
JWT_DEV_FALLBACK_SECRET = os.getenv('JWT_DEV_FALLBACK_SECRET', 'yasar-gold-dev-secret')

# هل نسمح بإرجاع توكن إعادة تعيين كلمة المرور في الاستجابة؟ (للتطوير فقط)
ALLOW_PASSWORD_RESET_TOKEN_RESPONSE = _env_bool('ALLOW_PASSWORD_RESET_TOKEN_RESPONSE', default=False)


# ╔════════════════════════════════════════════════════════════╗
# ║  Redis (Optional)                                          ║
# ╚════════════════════════════════════════════════════════════╝
# عند ضبط REDIS_URL سيتم استخدام Redis كطبقة تسريع لـ:
# - rate limiting
# - token blacklist cache
# - session cache

REDIS_URL = os.getenv('REDIS_URL', '').strip()
ENABLE_REDIS_CACHE = _env_bool('ENABLE_REDIS_CACHE', default=bool(REDIS_URL))


# ╔════════════════════════════════════════════════════════════╗
# ║  إعدادات الحسابات الداعمة لتسكير الوزن                    ║
# ╚════════════════════════════════════════════════════════════╝
#
# القائمة التالية تُستخدم لإنشاء وربط حسابات المصاريف/الفروقات
# مع حساباتها الوزنية (المذكرة) بشكل ديناميكي. يمكن إضافة أو تعديل
# العناصر هنا دون الحاجة لتعديل الكود الأساسي.

WEIGHT_SUPPORT_ACCOUNTS = [
	{
		'key': 'inventory_new',
		'financial': {
			'account_number': '1300',
			'name': 'مخزون ذهب معروض للبيع',
			'type': 'Asset',
			'transaction_type': 'cash',
			'tracks_weight': False,
			# في مخطط الحسابات الحالي الأب هو 130 (المخزون) وليس 13.
			'parent_number': '130',
		},
		'memo': {
			'account_number': '7130000',
			'name': 'مخزون ذهب معروض للبيع وزني',
			'type': 'Asset',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '7130',
		},
	},
	{
		'key': 'inventory_scrap',
		'financial': {
			'account_number': '1310',
			'name': 'مخزون ذهب كسر',
			'type': 'Asset',
			'transaction_type': 'cash',
			'tracks_weight': False,
			# في مخطط الحسابات الحالي الأب هو 130 (المخزون) وليس 13.
			'parent_number': '130',
		},
		'memo': {
			'account_number': '7130001',
			'name': 'مخزون ذهب كسر وزني',
			'type': 'Asset',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '7130',
		},
	},
	{
		'key': 'manufacturing_wage',
		'financial': {
			# NOTE: In this chart of accounts, 1350 is the cash wage-inventory account.
			# 1340 is used for 24k gold inventory (cash), whose memo should be 71330.
			'account_number': '1350',
			'name': 'مخزون أجور مصنعية',
			'type': 'Asset',
			'transaction_type': 'cash',
			'tracks_weight': False,
			# في مخطط الحسابات الحالي الأب هو 130 (المخزون) وليس 13.
			'parent_number': '130',
		},
		'memo': {
			'account_number': '71340',
			'name': 'مخزون أجور مصنعية وزني',
			'type': 'Asset',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '71',
		},
	},
	{
		'key': 'cleaning',
		'financial': {
			'account_number': '5110',
			'name': 'مصاريف نظافة',
			'type': 'Expense',
			'transaction_type': 'cash',
			'tracks_weight': False,
			'parent_number': '51',
		},
		'memo': {
			'account_number': '7510',
			'name': 'مصاريف نظافة وزنية',
			'type': 'Expense',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '75',
		},
	},
	{
		'key': 'melting',
		'financial': {
			'account_number': '5120',
			'name': 'مصاريف صهر',
			'type': 'Expense',
			'transaction_type': 'cash',
			'tracks_weight': False,
			'parent_number': '51',
		},
		'memo': {
			'account_number': '7520',
			'name': 'مصاريف صهر وزنية',
			'type': 'Expense',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '75',
		},
	},
	{
		'key': 'logistics',
		'financial': {
			'account_number': '5130',
			'name': 'مصاريف شحن وتغليف',
			'type': 'Expense',
			'transaction_type': 'cash',
			'tracks_weight': False,
			'parent_number': '51',
		},
		'memo': {
			'account_number': '7530',
			'name': 'مصاريف شحن وزنية',
			'type': 'Expense',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '75',
		},
	},
	{
		'key': 'valuation_diff',
		'financial': {
			'account_number': '3600',
			'name': 'فروقات تقييم الذهب',
			'type': 'Equity',
			'transaction_type': 'cash',
			'tracks_weight': False,
			'parent_number': '3',
		},
		'memo': {
			'account_number': '7600',
			'name': 'فروقات تقييم وزنية',
			'type': 'Equity',
			'transaction_type': 'gold',
			'tracks_weight': True,
			'parent_number': '73',  # الأب الصحيح: حقوق الملكية وزني
		},
	},
]


# ╔════════════════════════════════════════════════════════════╗
# ║  بروفايلات عمليات الوزن (يتم استخدامها لاحقاً في الخدمات)  ║
# ╚════════════════════════════════════════════════════════════╝
# هذه مجرد هيكل مبدئي وسيتم ملؤها خلال مراحل التطوير التالية.

WEIGHT_EXECUTION_PROFILES = {
	# مثال توضيحي، سيتم استكمال التفاصيل في الخطوات القادمة
	'cleaning': {
		'display_name': 'تنظيف الذهب',
		'support_account_key': 'cleaning',
		'execution_type': 'expense',
		'requires_cash_amount': True,
		'requires_weight': False,
		'price_strategy': 'live_or_manual',
	},
	'melting': {
		'display_name': 'عمليات الصهر',
		'support_account_key': 'melting',
		'execution_type': 'expense',
		'requires_cash_amount': True,
		'requires_weight': False,
		'price_strategy': 'live_or_manual',
	},
	'logistics': {
		'display_name': 'شحن وتغليف',
		'support_account_key': 'logistics',
		'execution_type': 'expense',
		'requires_cash_amount': True,
		'requires_weight': False,
		'price_strategy': 'live_or_manual',
	},
	'valuation_adjustment': {
		'display_name': 'تعديل فروقات التقييم',
		'support_account_key': 'valuation_diff',
		'execution_type': 'variance',
		'requires_cash_amount': False,
		'requires_weight': True,
		'price_strategy': 'reference_order',
	},
}

# يمكن لاحقاً إضافة إعدادات أخرى مثل سعر الأونصة المرجعي
