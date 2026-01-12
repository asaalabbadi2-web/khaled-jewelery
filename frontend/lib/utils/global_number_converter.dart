import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'arabic_number_formatter.dart';

/// Mixin يمكن إضافته لأي Widget لتطبيق تحويل الأرقام تلقائياً
mixin AutoNumberConversion {
  /// يضيف formatter لتحويل الأرقام إلى قائمة formatters موجودة
  List<TextInputFormatter> addNumberConversion(
    List<TextInputFormatter>? existingFormatters,
  ) {
    final formatters = existingFormatters ?? [];
    // تحقق من عدم وجود formatter مشابه بالفعل
    final hasNumberFormatter = formatters.any(
      (f) =>
          f is UniversalNumberTextInputFormatter ||
          f is ArabicNumberTextInputFormatter,
    );

    if (!hasNumberFormatter) {
      return [const UniversalNumberTextInputFormatter(), ...formatters];
    }
    return formatters;
  }
}

/// Extension على InputDecoration لإضافة تلميح للمستخدم
extension InputDecorationExtension on InputDecoration {
  InputDecoration withNumberConversion() {
    return copyWith(
      helperText: helperText ?? 'يتم تحويل الأرقام العربية والهندية تلقائياً',
      helperMaxLines: 2,
    );
  }
}

/// Widget wrapper لـ TextField يطبق التحويل تلقائياً
class UniversalTextField extends StatelessWidget {
  final TextEditingController? controller;
  final InputDecoration? decoration;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final TextInputAction? textInputAction;
  final bool enabled;
  final int? maxLines;
  final int? minLines;
  final bool obscureText;
  final FocusNode? focusNode;
  final String? initialValue;
  final bool autofocus;

  const UniversalTextField({
    super.key,
    this.controller,
    this.decoration,
    this.keyboardType,
    this.inputFormatters,
    this.onChanged,
    this.validator,
    this.textInputAction,
    this.enabled = true,
    this.maxLines = 1,
    this.minLines,
    this.obscureText = false,
    this.focusNode,
    this.initialValue,
    this.autofocus = false,
  });

  List<TextInputFormatter> _buildFormatters() {
    final formatters = inputFormatters ?? [];
    final hasNumberFormatter = formatters.any(
      (f) =>
          f is UniversalNumberTextInputFormatter ||
          f is ArabicNumberTextInputFormatter,
    );

    if (!hasNumberFormatter) {
      return [const UniversalNumberTextInputFormatter(), ...formatters];
    }
    return formatters;
  }

  @override
  Widget build(BuildContext context) {
    if (validator != null) {
      return TextFormField(
        controller: controller,
        decoration: decoration,
        keyboardType: keyboardType,
        inputFormatters: _buildFormatters(),
        onChanged: onChanged,
        validator: validator,
        textInputAction: textInputAction,
        enabled: enabled,
        maxLines: maxLines,
        minLines: minLines,
        obscureText: obscureText,
        focusNode: focusNode,
        initialValue: initialValue,
        autofocus: autofocus,
      );
    }

    return TextField(
      controller: controller,
      decoration: decoration,
      keyboardType: keyboardType,
      inputFormatters: _buildFormatters(),
      onChanged: onChanged,
      textInputAction: textInputAction,
      enabled: enabled,
      maxLines: maxLines,
      minLines: minLines,
      obscureText: obscureText,
      focusNode: focusNode,
      autofocus: autofocus,
    );
  }
}

/// Helper function لإضافة تحويل الأرقام لأي TextField أو TextFormField
List<TextInputFormatter> withNumberConversion([
  List<TextInputFormatter>? formatters,
]) {
  final list = formatters ?? [];
  final hasNumberFormatter = list.any(
    (f) =>
        f is UniversalNumberTextInputFormatter ||
        f is ArabicNumberTextInputFormatter,
  );

  if (!hasNumberFormatter) {
    return [const UniversalNumberTextInputFormatter(), ...list];
  }
  return list;
}
