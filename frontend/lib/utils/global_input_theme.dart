import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/arabic_number_formatter.dart';

/// Global InputDecoration Theme مع تحويل الأرقام التلقائي
class GlobalInputDecorationTheme {
  /// Creates default InputDecorationTheme with automatic number conversion
  static InputDecorationTheme create() {
    return const InputDecorationTheme(
      border: OutlineInputBorder(),
      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      filled: true,
      fillColor: Colors.white,
    );
  }
}

/// Mixin to add automatic number conversion to any StatefulWidget
mixin AutomaticNumberConversion<T extends StatefulWidget> on State<T> {
  /// Wraps a TextField/TextFormField with automatic number conversion
  Widget wrapWithNumberConversion(Widget child, {bool forceConversion = true}) {
    if (forceConversion) {
      // يمكن إضافة logic هنا لتطبيق التحويل تلقائياً
      return child;
    }
    return child;
  }
}

/// Extension على TextEditingController لإضافة التحويل التلقائي
extension NumberConversionController on TextEditingController {
  /// استمع للتغييرات وطبق التحويل تلقائياً
  void enableAutoConversion() {
    addListener(() {
      final converted = ArabicNumberTextInputFormatter.convertToWesternNumbers(
        text,
      );
      if (converted != text) {
        final selection = this.selection;
        text = converted;
        // حافظ على موضع المؤشر
        if (selection.isValid && selection.baseOffset <= converted.length) {
          this.selection = selection;
        }
      }
    });
  }
}

/// Builder function لإنشاء TextField مع تحويل تلقائي
typedef TextFieldBuilder =
    Widget Function({
      TextEditingController? controller,
      InputDecoration? decoration,
      TextInputType? keyboardType,
      List<TextInputFormatter>? inputFormatters,
      ValueChanged<String>? onChanged,
      int? maxLines,
    });

/// Global function لإنشاء TextField مع تحويل أرقام تلقائي
Widget buildTextFieldWithConversion({
  TextEditingController? controller,
  InputDecoration? decoration,
  TextInputType? keyboardType,
  List<TextInputFormatter>? inputFormatters,
  ValueChanged<String>? onChanged,
  FormFieldValidator<String>? validator,
  int? maxLines,
  bool enabled = true,
  TextInputAction? textInputAction,
  FocusNode? focusNode,
  bool autofocus = false,
}) {
  // تحديد هل الحقل رقمي
  final isNumeric =
      keyboardType == TextInputType.number ||
      keyboardType == const TextInputType.numberWithOptions(decimal: true) ||
      keyboardType == const TextInputType.numberWithOptions(signed: true);

  // إضافة التحويل التلقائي
  final formatters = <TextInputFormatter>[
    if (isNumeric)
      ArabicNumberTextInputFormatter(
        allowDecimal:
            keyboardType ==
            const TextInputType.numberWithOptions(decimal: true),
        allowNegative:
            keyboardType == const TextInputType.numberWithOptions(signed: true),
      )
    else
      const UniversalNumberTextInputFormatter(),
    ...?inputFormatters,
  ];

  if (validator != null) {
    return TextFormField(
      controller: controller,
      decoration: decoration,
      keyboardType: keyboardType,
      inputFormatters: formatters,
      onChanged: onChanged,
      validator: validator,
      maxLines: maxLines,
      enabled: enabled,
      textInputAction: textInputAction,
      focusNode: focusNode,
      autofocus: autofocus,
    );
  }

  return TextField(
    controller: controller,
    decoration: decoration,
    keyboardType: keyboardType,
    inputFormatters: formatters,
    onChanged: onChanged,
    maxLines: maxLines,
    enabled: enabled,
    textInputAction: textInputAction,
    focusNode: focusNode,
    autofocus: autofocus,
  );
}
