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


# The weight-closing profiles (WEIGHT_EXECUTION_PROFILES) went with their execute
# screen (ADR-048 phase 3c): never run on production; a marked expense's own
# voucher closes its riyals in the weight position.
