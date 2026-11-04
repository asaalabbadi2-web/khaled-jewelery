// REPORTS ت6-2ب (ADR-083): the payroll report on the reports' shell. The
// journey: it opens on the year so far by month; the check says the gap with
// the books; «حسب» reads again; an employee opens his page.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/employee_page.dart';
import 'package:frontend/screens/payroll_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <(String, String, String)>[];

  @override
  Future<Map<String, dynamic>> getPayrollReport({
    required String startDate,
    required String endDate,
    String by = 'month',
  }) async {
    asked.add((startDate, endDate, by));
    final employee = by == 'employee';
    return {
      'id': 'payroll',
      'title': 'تقرير الرواتب',
      'basis': 'documents',
      'period': {'start': startDate, 'end': endDate},
      'columns': [
        {
          'key': 'group',
          'label': employee ? 'الموظف' : 'الشهر',
          'kind': 'text',
        },
        {'key': 'earned', 'label': 'المستحق', 'kind': 'money'},
        {'key': 'bonuses', 'label': 'المكافآت', 'kind': 'money'},
        {'key': 'net', 'label': 'الصافي', 'kind': 'money'},
        {'key': 'expense', 'label': 'مصروف الرواتب', 'kind': 'money'},
      ],
      'rows': [
        {
          'group': employee ? 'يوسف الشعبي' : '2026-10',
          'earned': 45000.0,
          'bonuses': 22385.0,
          'net': 48535.0,
          'expense': 41667.0,
          'drill': employee ? {'kind': 'employee', 'id': 18} : null,
        },
      ],
      'totals': {'net': 48535.0, 'expense': 41667.0},
      'checks': [
        {
          'key': 'books_agree',
          'label':
              'لا يطابق مصروف الرواتب في الدفاتر: المسير أقل بـ 250.00 (الدفاتر 41,917.00)',
          'ok': false,
        },
      ],
      'read_at': '2026-11-04T10:32:00',
    };
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('the year so far by month; the gap said; an employee opens '
      'his page', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PayrollReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.asked.single, ('2026-01-01', '2026-10-31', 'month'));
    expect(find.textContaining('أقل بـ 250.00'), findsOneWidget);
    await tester.tap(find.text('الموظف').first);
    await _settle(tester);
    expect(server.asked.last.$3, 'employee');
    await tester.tap(find.text('يوسف الشعبي'));
    await _settle(tester);
    expect(find.byType(EmployeePage), findsOneWidget);
  });
}
