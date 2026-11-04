// REPORTS ت6-3 (ADR-083): the bonuses owed on the reports' shell. The
// journey: it opens on today; a difference between the documents and the
// books is a finding, the check says by how much; an employee opens his page.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/employee_page.dart';
import 'package:frontend/screens/reports/bonus_payables_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final days = <String>[];

  @override
  Future<Map<String, dynamic>> getBonusesPayablesReport({
    required String asOf,
  }) async {
    days.add(asOf);
    return {
      'id': 'bonus_payables',
      'title': 'المكافآت المستحقة',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': asOf},
      'columns': [
        {'key': 'name', 'label': 'الموظف', 'kind': 'text'},
        {'key': 'documents', 'label': 'المعتمدة غير المصروفة', 'kind': 'money'},
        {
          'key': 'books',
          'label': 'المستحق في الدفاتر',
          'kind': 'money',
          'signed': true,
        },
        {
          'key': 'difference',
          'label': 'الفرق',
          'kind': 'money',
          'signed': true,
        },
      ],
      'rows': [
        {
          'name': 'مسعد المهري',
          'documents': 2512.5,
          'books': 0.0,
          'difference': 2512.5,
          'style': 'finding',
          'drill': {'kind': 'employee', 'id': 16},
        },
      ],
      'totals': {'documents': 2512.5, 'books': 0.0, 'difference': 2512.5},
      'checks': [
        {
          'key': 'books_agree',
          'label':
              'المكافآت المعتمدة غير المصروفة أكثر من المستحق في الدفاتر بـ 2,512.50 — الدفاتر هي الصحيحة',
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
  testWidgets('it opens on today; the gap said; an employee opens his page', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: BonusPayablesReportScreen(
            api: server,
            now: () => DateTime(2026, 9, 30),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.days.single, '2026-09-30');
    expect(find.textContaining('الدفاتر هي الصحيحة'), findsOneWidget);
    await tester.tap(find.text('مسعد المهري'));
    await _settle(tester);
    expect(find.byType(EmployeePage), findsOneWidget);
  });
}
