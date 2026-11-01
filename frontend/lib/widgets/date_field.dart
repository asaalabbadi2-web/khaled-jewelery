import 'package:flutter/material.dart';

/// A date's field (HR-UX ر5; the owner's approved design): its calendar one
/// tap away, its typing kept for who types fast -- written as the server
/// reads it, YYYY-MM-DD. Every HR date field is this one.
String isoDate(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';

/// The calendar, its pick written into the field.
Future<void> pickDateInto(
  BuildContext context,
  TextEditingController controller,
) async {
  final current = DateTime.tryParse(controller.text.trim());
  final picked = await showDatePicker(
    context: context,
    initialDate: current ?? DateTime.now(),
    firstDate: DateTime(1950),
    lastDate: DateTime(2100),
  );
  if (picked != null) controller.text = isoDate(picked);
}

/// The calendar's button, for a field built elsewhere (a form's validator kept).
Widget dateSuffix(
  BuildContext context,
  TextEditingController controller, {
  Key? key,
}) => IconButton(
  key: key,
  tooltip: Directionality.of(context) == TextDirection.rtl
      ? 'اختر من التقويم'
      : 'Pick a date',
  icon: const Icon(Icons.calendar_month_outlined),
  onPressed: () => pickDateInto(context, controller),
);

class DateField extends StatelessWidget {
  const DateField({
    super.key,
    required this.controller,
    required this.label,
    this.pickerKey,
  });

  final TextEditingController controller;
  final String label;

  /// The calendar button's key, for its tests.
  final Key? pickerKey;

  @override
  Widget build(BuildContext context) => TextField(
    controller: controller,
    textDirection: TextDirection.ltr,
    keyboardType: TextInputType.datetime,
    decoration: InputDecoration(
      labelText: label,
      hintText: 'YYYY-MM-DD',
      suffixIcon: dateSuffix(context, controller, key: pickerKey),
    ),
  );
}
