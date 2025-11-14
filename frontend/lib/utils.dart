import 'package:flutter/services.dart';

/// TextInputFormatter مخصص لتحويل الأرقام العربية والهندية والفارسية إلى أرقام عالمية أثناء الإدخال
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
String normalizeNumber(String? input) {
  if (input == null) return '';
  const eastern = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  String text = input;
  for (int i = 0; i < 10; i++) {
    text = text.replaceAll(eastern[i], i.toString());
    text = text.replaceAll(persian[i], i.toString());
  }
  return text;
}
