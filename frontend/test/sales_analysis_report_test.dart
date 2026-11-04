// REPORTS ت1-2 (ADR-083): sales analysis on the reports' shell. The journey:
// it opens on this month by employee; «حسب» reads again by the one chosen;
// compared, the previous period's column comes; the books' agreement is said;
// a share is written as a percent; an employee's row opens his page, a
// customer's his statement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/employee_page.dart';
import 'package:frontend/screens/reports/sales_analysis_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <({String? start, String? end, String by, bool compare})>[];

  @override
  Future<Map<String, dynamic>> getSalesAnalysis({
    String? startDate,
    String? endDate,
    String by = 'employee',
    bool compare = false,
  }) async {
    asked.add((start: startDate, end: endDate, by: by, compare: compare));
    final employee = by == 'employee';
    return {
      'id': 'sales_analysis',
      'title': 'تحليل المبيعات',
      'basis': 'documents',
      'period': {'start': startDate, 'end': endDate},
      'columns': [
        {
          'key': 'group',
          'label': employee ? 'الموظف' : 'العميل',
          'kind': 'text',
        },
        {'key': 'invoices', 'label': 'الفواتير', 'kind': 'count'},
        {'key': 'value', 'label': 'القيمة', 'kind': 'money'},
        {'key': 'share', 'label': 'الحصة', 'kind': 'percent'},
        if (compare) ...[
          {'key': 'prev_value', 'label': 'الفترة السابقة', 'kind': 'money'},
          {
            'key': 'change',
            'label': 'التغيّر',
            'kind': 'percent',
            'signed': true,
          },
        ],
        if (by == 'customer')
          {'key': 'last', 'label': 'آخر بيع', 'kind': 'date'},
      ],
      'rows': [
        {
          'group_id': 19,
          'group': employee ? 'عبدالله قرنان' : 'عميل نقدي',
          'invoices': 67,
          'value': 434670.0,
          'share': 31.18,
          'prev_value': 290775.0,
          'change': 49.49,
          'last': '2026-10-31',
          'drill': {'kind': employee ? 'employee' : 'customer', 'id': 19},
        },
      ],
      'totals': {'invoices': 67, 'value': 434670.0, 'share': 100.0},
      'checks': [
        {
          'key': 'books_agree',
          'label': 'مطابق لإيراد المبيعات في الدفاتر',
          'ok': true,
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

Future<_Server> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  await tester.pumpWidget(
    MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: SalesAnalysisReportScreen(
          api: server,
          now: () => DateTime(2026, 11, 4),
        ),
      ),
    ),
  );
  await _settle(tester);
  return server;
}

void main() {
  testWidgets(
    'it opens on this month by employee, the books\' agreement said',
    (tester) async {
      final server = await _open(tester);
      expect(server.asked.single, (
        start: '2026-11-01',
        end: '2026-11-04',
        by: 'employee',
        compare: false,
      ));
      expect(
        find.byKey(const ValueKey('report-check-books_agree')),
        findsOneWidget,
      );
      expect(
        find.text('31.18%'),
        findsOneWidget,
        reason: 'a share as a percent',
      );
    },
  );

  testWidgets('by category, karat and gold type (REPORTS ت4-1); the last '
      'sale is a date read left to right, not the wide column', (tester) async {
    final server = await _open(tester);
    for (final (label, by) in [
      ('التصنيف', 'category'),
      ('الصنف', 'item'),
      ('العيار', 'karat'),
      ('نوع الذهب', 'gold_type'),
    ]) {
      await tester.tap(find.text(label).first);
      await _settle(tester);
      expect(server.asked.last.by, by);
    }
    await tester.tap(find.text('العميل').first);
    await _settle(tester);
    expect(find.byKey(const ValueKey('report-head-last')), findsOneWidget);
    final date = tester.widget<Text>(find.text('2026-10-31'));
    expect(date.textDirection, TextDirection.ltr);
  });

  testWidgets('«حسب» reads again; compared, the previous period comes', (
    tester,
  ) async {
    final server = await _open(tester);
    await tester.tap(find.text('العميل').first);
    await _settle(tester);
    expect(server.asked.last.by, 'customer');
    await tester.tap(find.byKey(const ValueKey('report-toggle-compare')));
    await _settle(tester);
    expect(server.asked.last.compare, isTrue);
    expect(
      find.byKey(const ValueKey('report-head-prev_value')),
      findsOneWidget,
    );
    expect(find.text('49.49%'), findsOneWidget);
  });

  testWidgets(
    'an employee\'s row opens his page, a customer\'s his statement',
    (tester) async {
      await _open(tester);
      await tester.tap(find.text('عبدالله قرنان'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(
        tester.widget<EmployeePage>(find.byType(EmployeePage)).employeeId,
        19,
      );
      Navigator.of(tester.element(find.byType(EmployeePage))).pop();
      await _settle(tester);
      await tester.tap(find.text('العميل').first);
      await _settle(tester);
      await tester.tap(find.text('عميل نقدي'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final statement = tester.widget<AccountStatementScreen>(
        find.byType(AccountStatementScreen),
      );
      expect((statement.accountId, statement.entityType), (19, 'customer'));
    },
  );
}
