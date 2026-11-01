import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/employee_model.dart';
import 'package:frontend/screens/employees_screen.dart';
import 'package:frontend/theme/app_theme.dart';

/// HR-UX ط1 (the owner, 2 Nov 2026, «اعتمد»): the file's edit writes none of
/// what another document owns -- his salary (shown as «الراتب الأساسي», it
/// was the gross the structure wrote, and no run read it), his leaving date
/// (the settlement's), his stop (the page head's).
void main() {
  testWidgets('no salary, no leaving date, no status; none sent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Map<String, dynamic>? sent;
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () async {
                sent = await showDialog<Map<String, dynamic>?>(
                  context: context,
                  builder: (_) => EmployeeFormDialog(
                    api: ApiService(),
                    isArabic: true,
                    employee: EmployeeModel.fromJson({
                      'id': 7,
                      'name': 'مسعد المهري',
                      'salary': 7000.0,
                      'hire_date': '2025-03-15',
                      'is_active': true,
                    }),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('الراتب الأساسي'), findsNothing);
    expect(find.text('تاريخ الإنهاء'), findsNothing);
    expect(find.text('الحالة نشطة'), findsNothing);
    expect(find.byKey(const ValueKey('employee-hire-date')), findsOneWidget);

    await tester.tap(find.text('حفظ'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(sent, isNotNull);
    expect(sent!['hire_date'], '2025-03-15');
    for (final key in ['salary', 'termination_date', 'is_active']) {
      expect(
        sent!.containsKey(key),
        isFalse,
        reason: '$key is not the file\'s',
      );
    }
  });
}
