import 'package:flutter/material.dart';

/// Widget مشترك لإدخال سبب الإرجاع
/// يستخدم في شاشات المرتجعات
class ReturnReasonInput extends StatelessWidget {
  final TextEditingController controller;
  final bool isRequired;
  final int maxLines;
  final String? labelText;
  final String? hintText;
  final String? helperText;

  const ReturnReasonInput({
    super.key,
    required this.controller,
    this.isRequired = true,
    this.maxLines = 4,
    this.labelText,
    this.hintText,
    this.helperText,
  });

  @override
  Widget build(BuildContext context) {
    final bool isAr = Localizations.localeOf(context).languageCode == 'ar';

    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: labelText ?? (isAr ? 'سبب الإرجاع' : 'Return Reason'),
        hintText:
            hintText ??
            (isAr ? 'أدخل سبب إرجاع البضاعة...' : 'Enter reason for return...'),
        helperText:
            helperText ??
            (isAr
                ? 'مطلوب: اذكر السبب بشكل واضح'
                : 'Required: State reason clearly'),
        border: const OutlineInputBorder(),
        alignLabelWithHint: true,
        prefixIcon: const Icon(Icons.comment),
      ),
      validator: (value) {
        if (isRequired && (value == null || value.trim().isEmpty)) {
          return isAr
              ? 'الرجاء إدخال سبب الإرجاع'
              : 'Please enter return reason';
        }
        if (value != null && value.trim().length < 5) {
          return isAr
              ? 'سبب الإرجاع يجب أن يكون 5 أحرف على الأقل'
              : 'Return reason must be at least 5 characters';
        }
        return null;
      },
    );
  }
}
