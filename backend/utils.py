

# دالة لتحويل أي أرقام عربية أو هندية أو فارسية إلى أرقام عالمية (0-9)
def normalize_number(text):
    eastern = '٠١٢٣٤٥٦٧٨٩'
    persian = '۰۱۲۳۴۵۶۷۸۹'
    for i in range(10):
        text = text.replace(eastern[i], str(i))
        text = text.replace(persian[i], str(i))
    return text


def get_main_karat():
    """العيار الرئيسي من الإعدادات -- القارئ الواحد (pricing.gold_price_service)؛
    يرفض إن لم يُضبط، ولا عيار ثابت بديلًا عنه (المالك، 20 أكتوبر 2026)."""
    from pricing.gold_price_service import get_main_karat as _settings_main_karat
    return _settings_main_karat()
