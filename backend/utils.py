# دالة لتحويل أي أرقام عربية أو هندية أو فارسية إلى أرقام عالمية (0-9)
def normalize_number(text):
    eastern = '٠١٢٣٤٥٦٧٨٩'
    persian = '۰۱۲۳۴۵۶۷۸۹'
    for i in range(10):
        text = text.replace(eastern[i], str(i))
        text = text.replace(persian[i], str(i))
    return text
