import 'package:flutter/material.dart';

/// Widget مشترك لاختيار نوع الذهب (جديد/كسر)
/// يستخدم في شاشات الفواتير التي تحتاج هذا الاختيار
class GoldTypeSelector extends StatelessWidget {
  final String selectedGoldType;
  final ValueChanged<String?> onChanged;
  final bool isEnabled;
  final String? labelText;

  const GoldTypeSelector({
    super.key,
    required this.selectedGoldType,
    required this.onChanged,
    this.isEnabled = true,
    this.labelText,
  });

  @override
  Widget build(BuildContext context) {
    final bool isAr = Localizations.localeOf(context).languageCode == 'ar';

    return DropdownButtonFormField<String>(
      initialValue: selectedGoldType,
      decoration: InputDecoration(
        labelText: labelText ?? (isAr ? 'نوع الذهب' : 'Gold Type'),
        border: const OutlineInputBorder(),
        enabled: isEnabled,
      ),
      items: [
        DropdownMenuItem(
          value: 'new',
          child: Row(
            children: [
              Icon(Icons.fiber_new, color: Colors.green.shade300, size: 20),
              const SizedBox(width: 8),
              Text(isAr ? 'ذهب جديد' : 'New Gold'),
            ],
          ),
        ),
        DropdownMenuItem(
          value: 'scrap',
          child: Row(
            children: [
              Icon(Icons.recycling, color: Colors.orange.shade300, size: 20),
              const SizedBox(width: 8),
              Text(isAr ? 'ذهب كسر' : 'Scrap Gold'),
            ],
          ),
        ),
      ],
      onChanged: isEnabled ? onChanged : null,
      validator: (value) {
        if (value == null || value.isEmpty) {
          return isAr ? 'الرجاء اختيار نوع الذهب' : 'Please select gold type';
        }
        return null;
      },
    );
  }
}
