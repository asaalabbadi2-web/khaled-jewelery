import 'package:flutter/services.dart';

/// يحول الأرقام العربية إلى أرقام إنجليزية للسماح بإدخال الأرقام بشكل موحد.
class ArabicNumberTextInputFormatter extends TextInputFormatter {
  const ArabicNumberTextInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final newText = _convertArabicNumbers(newValue.text);
    final regExp = RegExp(r'^\d*\.?\d*$', unicode: true);

    if (regExp.hasMatch(newText)) {
      return TextEditingValue(text: newText, selection: newValue.selection);
    }
    return oldValue;
  }

  String _convertArabicNumbers(String input) {
    const arabic = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
    const english = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];

    var output = input;
    for (var i = 0; i < arabic.length; i++) {
      output = output.replaceAll(arabic[i], english[i]);
    }
    return output;
  }
}
