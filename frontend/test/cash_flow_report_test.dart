// REPORTS ت2-3 (ADR-083): the cash flow on the reports' shell. The journey:
// it opens on this month; «all» is this year to today (a flow is of a
// period); its activities, their totals and the cash before and after are
// drawn; its check is said; a line opens the trial balance of its group's
// accounts for that period.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/cash_flow_report_screen.dart';
import 'package:frontend/screens/reports/trial_balance_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <(String, String)>[];

  @override
  Future<Map<String, dynamic>> getCashFlow({
    required String startDate,
    required String endDate,
  }) async {
    asked.add((startDate, endDate));
    Map<String, dynamic> row(
      String key,
      String name, {
      num? inflow,
      num? outflow,
      num? net,
      String? style,
      int? id,
    }) => {
      'key': key,
      'name': name,
      'inflow': inflow,
      'outflow': outflow,
      'net': net,
      'style': style,
      'drill': id == null ? null : {'kind': 'account', 'id': id},
    };
    return {
      'id': 'cash_flow',
      'title': 'التدفقات النقدية',
      'basis': 'posted_entries',
      'period': {'start': startDate, 'end': endDate},
      'columns': [
        {'key': 'name', 'label': 'البند', 'kind': 'text'},
        {'key': 'inflow', 'label': 'داخل', 'kind': 'money'},
        {'key': 'outflow', 'label': 'خارج', 'kind': 'money'},
        {'key': 'net', 'label': 'الصافي', 'kind': 'money', 'signed': true},
      ],
      'rows': [
        row('operating', 'التدفق من التشغيل', style: 'heading'),
        row(
          'operating_120',
          'العملاء',
          inflow: 1245312.1,
          outflow: 555769.0,
          net: 689543.1,
          id: 120,
        ),
        row(
          'operating_total',
          'صافي التدفق من التشغيل',
          inflow: 1932967.26,
          outflow: 1761217.23,
          net: 171750.03,
          style: 'subtotal',
        ),
        row('closing', 'النقد آخر الفترة', net: 426580.59, style: 'subtotal'),
      ],
      'totals': <String, dynamic>{},
      'checks': [
        {
          'key': 'flow_closes',
          'label': 'النقد أول الفترة + صافي التدفق = النقد آخرها',
          'ok': true,
        },
      ],
      'read_at': '2026-11-04T10:32:00',
    };
  }

  @override
  Future<Map<String, dynamic>> getTrialBalance({
    String? startDate,
    String? endDate,
    bool karatDetail = false,
    int? under,
  }) async => {
    'id': 'trial_balance',
    'title': 'ميزان المراجعة',
    'basis': 'posted_entries',
    'period': {'start': startDate, 'end': endDate},
    'columns': [
      {'key': 'account_name', 'label': 'الحساب', 'kind': 'text'},
    ],
    'rows': [
      {'account_name': 'عميل نقدي'},
    ],
    'totals': <String, dynamic>{},
    'checks': [],
    'read_at': '2026-11-04T10:32:00',
  };
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('it opens on this month; «all» is this year; a line opens its '
      'group\'s accounts for the period', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CashFlowReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.asked.single, ('2026-10-01', '2026-10-31'));
    expect(
      find.byKey(const ValueKey('report-check-flow_closes')),
      findsOneWidget,
    );
    expect(find.text('النقد آخر الفترة'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('report-period')));
    await _settle(tester);
    await tester.tap(find.text('كل الفترات').last);
    await _settle(tester);
    expect(server.asked.last, ('2026-01-01', '2026-10-31'));

    await tester.tap(find.text('العملاء'));
    await _settle(tester);
    final trial = tester.widget<TrialBalanceReportScreen>(
      find.byType(TrialBalanceReportScreen),
    );
    expect(trial.under, 120);
    expect(trial.range, isNotNull, reason: 'for the period the flow read');
  });
}
