import 'package:flutter/services.dart';

/// TextInputFormatter مخصص لتحويل الأرقام العربية والهندية والفارسية إلى أرقام عالمية أثناء الإدخال
///
/// هذا الـ formatter يحول تلقائياً:
/// - الأرقام العربية (٠-٩)
/// - الأرقام الهندية/الفارسية (۰-۹)
/// إلى أرقام عالمية (0-9)
class NormalizeNumberFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final normalized = normalizeNumber(newValue.text);
    return TextEditingValue(
      text: normalized,
      selection: TextSelection.collapsed(offset: normalized.length),
    );
  }
}

/// دالة لتحويل أي أرقام عربية أو هندية أو فارسية إلى أرقام عالمية (0-9)
///
/// يدعم:
/// - الأرقام العربية الشرقية: ٠ ١ ٢ ٣ ٤ ٥ ٦ ٧ ٨ ٩
/// - الأرقام الفارسية/الهندية: ۰ ۱ ۲ ۳ ۴ ۵ ۶ ۷ ۸ ۹
///
/// مثال:
/// ```dart
/// normalizeNumber('٢٣.٥') // returns '23.5'
/// normalizeNumber('۱۲۳') // returns '123'
/// normalizeNumber('الوزن: ٢٣.٥ جرام') // returns 'الوزن: 23.5 جرام'
/// ```
String normalizeNumber(String? input) {
  if (input == null || input.isEmpty) return '';

  // الأرقام العربية الشرقية
  const eastern = '٠١٢٣٤٥٦٧٨٩';
  // الأرقام الفارسية/الهندية (Urdu, Persian)
  const persian = '۰۱۲۳۴۵۶۷۸۹';

  String text = input;

  // تحويل الأرقام العربية
  for (int i = 0; i < 10; i++) {
    text = text.replaceAll(eastern[i], i.toString());
  }

  // تحويل الأرقام الفارسية/الهندية
  for (int i = 0; i < 10; i++) {
    text = text.replaceAll(persian[i], i.toString());
  }

  return text;
}
