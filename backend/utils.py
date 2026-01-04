try:
    from backend.config import MAIN_KARAT
except ImportError:  # Local scripts running from backend/ directory
    from config import MAIN_KARAT
from models import Settings


# دالة لتحويل أي أرقام عربية أو هندية أو فارسية إلى أرقام عالمية (0-9)
def normalize_number(text):
    eastern = '٠١٢٣٤٥٦٧٨٩'
    persian = '۰۱۲۳۴۵۶۷۸۹'
    for i in range(10):
        text = text.replace(eastern[i], str(i))
        text = text.replace(persian[i], str(i))
    return text


def get_main_karat(default=MAIN_KARAT):
    """الحصول على العيار الرئيسي للنظام من إعدادات قاعدة البيانات."""
    settings = Settings.query.first()
    main_karat = getattr(settings, 'main_karat', None)
    return main_karat or default
