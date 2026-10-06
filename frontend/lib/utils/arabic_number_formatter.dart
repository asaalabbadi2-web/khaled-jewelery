import 'package:flutter/services.dart';

import '../utils.dart';

/// يحول الأرقام العربية والهندية إلى أرقام عالمية (western digits) للسماح بإدخال الأرقام بشكل موحد.
class ArabicNumberTextInputFormatter extends TextInputFormatter {
  final bool allowDecimal;
  final bool allowNegative;

  const ArabicNumberTextInputFormatter({
    this.allowDecimal = true,
    this.allowNegative = false,
  });

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final newText = convertToWesternNumbers(newValue.text);

    // بناء regex بناءً على الخيارات
    String pattern = '';
    if (allowNegative) pattern += r'-?';
    pattern += r'\d*';
    if (allowDecimal) pattern += r'\.?\d*';
    pattern = '^$pattern\$';

    final regExp = RegExp(pattern, unicode: true);

    if (regExp.hasMatch(newText)) {
      return TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: newText.length),
      );
    }
    return oldValue;
  }

  /// يحول الأرقام العربية (٠-٩) والهندية (۰-۹) إلى أرقام عالمية (0-9)، والفاصلة
  /// العشرية العربية «٫» إلى نقطة. تحويل واحد للتطبيق: [normalizeNumber].
  static String convertToWesternNumbers(String input) => normalizeNumber(input);
}

/// formatter عام لحقول النص التي تقبل أي نوع من المحتوى مع تحويل الأرقام
class UniversalNumberTextInputFormatter extends TextInputFormatter {
  const UniversalNumberTextInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final newText = ArabicNumberTextInputFormatter.convertToWesternNumbers(
      newValue.text,
    );

    return TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
    );
  }
}
