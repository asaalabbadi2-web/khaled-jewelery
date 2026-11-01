import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/date_field.dart';

/// HR-UX ر5: a date's field has its calendar one tap away, its pick written
/// as the server reads it; typing is kept.
void main() {
  test('a day is written as the server reads it', () {
    expect(isoDate(DateTime(2026, 3, 7)), '2026-03-07');
  });

  testWidgets(
    'the calendar\'s pick is written into the field; typing is kept',
    (tester) async {
      final controller = TextEditingController(text: '2026-11-10');
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: Scaffold(
            body: DateField(
              controller: controller,
              label: 'من',
              pickerKey: const ValueKey('pick'),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('pick')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('20'));
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(
        controller.text,
        '2026-11-20',
        reason: 'opened on the field\'s own day, its month',
      );

      await tester.enterText(find.byType(TextField), '2027-01-05');
      expect(controller.text, '2027-01-05');
    },
  );
}
