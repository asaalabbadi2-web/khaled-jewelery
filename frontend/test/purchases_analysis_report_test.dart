// REPORTS ت4-4أ (ADR-083): the purchases analysis on the reports' shell. The
// journey: it opens on this month by kind; «حسب» reads again; the check says
// whether the books agree, and by how much when they do not; a supplier's row
// opens its statement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/purchases_analysis_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <({String? start, String? end, String by})>[];
  final against = <bool>[];

  @override
  Future<Map<String, dynamic>> getPurchasesAnalysis({
    String? startDate,
    String? endDate,
    String by = 'kind',
    bool compare = false,
    bool againstSales = false,
  }) async {
    asked.add((start: startDate, end: endDate, by: by));
    against.add(againstSales);
    final party = by == 'party';
    if (by == 'month') {
      return {
        'id': 'purchases_analysis',
        'title': 'تحليل المشتريات',
        'basis': 'documents',
        'period': {'start': startDate, 'end': endDate},
        'columns': [
          {'key': 'group', 'label': 'الشهر', 'kind': 'text'},
          {'key': 'value', 'label': 'الريال', 'kind': 'money'},
          {'key': 'sales_value', 'label': 'المبيعات (ريال)', 'kind': 'money'},
        ],
        'rows': [
          {'group': '2026-09', 'value': 759610.18, 'sales_value': 936987.0},
          {'group': '2026-10', 'value': 1068611.57, 'sales_value': 1394020.1},
        ],
        'totals': <String, dynamic>{},
        'checks': [],
        'chart': {
          'x': 'group',
          'y': 'value',
          if (againstSales) 'also': ['sales_value'],
        },
        'read_at': '2026-11-04T10:32:00',
      };
    }
    return {
      'id': 'purchases_analysis',
      'title': 'تحليل المشتريات',
      'basis': 'documents',
      'period': {'start': startDate, 'end': endDate},
      'columns': [
        {'key': 'group', 'label': party ? 'الطرف' : 'النوع', 'kind': 'text'},
        {'key': 'invoices', 'label': 'الفواتير', 'kind': 'count'},
        {'key': 'value', 'label': 'الريال', 'kind': 'money'},
        {'key': 'weight', 'label': 'الوزن', 'kind': 'grams'},
      ],
      'rows': [
        {
          'group': party ? 'مفيد الحبيشي' : 'من الموردين',
          'invoices': 17,
          'value': 26693.98,
          'weight': 3462.653,
          'drill': party ? {'kind': 'supplier', 'id': 11} : null,
        },
      ],
      'totals': {'invoices': 17, 'value': 26693.98, 'weight': 3462.653},
      'checks': [
        {
          'key': 'books_agree',
          'label': party
              ? 'مطابق لحسابات المشتريات وأجور المصنعية في الدفاتر'
              : 'لا يطابق حسابات المشتريات وأجور المصنعية في الدفاتر: المستندات أكثر بـ 246,033.60 (الدفاتر 218,825.57)',
          'ok': party,
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
  testWidgets('by kind on this month; the gap said; a supplier opens its '
      'statement', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PurchasesAnalysisReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.asked.single, (
      start: '2026-10-01',
      end: '2026-10-31',
      by: 'kind',
    ));
    expect(find.textContaining('أكثر بـ 246,033.60'), findsOneWidget);
    expect(find.text('3,462.653'), findsWidgets);

    await tester.tap(find.text('الطرف').first);
    await _settle(tester);
    expect(server.asked.last.by, 'party');
    await tester.tap(find.text('مفيد الحبيشي'));
    await _settle(tester);
    final statement = tester.widget<AccountStatementScreen>(
      find.byType(AccountStatementScreen),
    );
    expect((statement.accountId, statement.entityType), (11, 'supplier'));
  });

  testWidgets('against sales the chart draws both, a legend naming each '
      '(REPORTS ت4-4ب)', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PurchasesAnalysisReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.text('الشهر').first);
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('report-chart-legend')),
      findsNothing,
      reason: 'one series: its title names it',
    );
    await tester.tap(find.byKey(const ValueKey('report-toggle-against_sales')));
    await _settle(tester);
    expect(server.against.last, isTrue);
    expect(find.byKey(const ValueKey('report-chart-legend')), findsOneWidget);
    expect(find.text('الريال والمبيعات (ريال) حسب الشهر'), findsOneWidget);
  });
}
