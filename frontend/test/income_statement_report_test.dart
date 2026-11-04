// REPORTS ت2-2ب (ADR-083): the income statement on the reports' shell. The
// journey: it opens on the period the dashboard gives it; «all» is this year
// to today (a statement is of a period); its riyals and the gram profit's
// five layers are drawn, the margin and the averages as notes; an account
// opens its statement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/income_statement_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <(DateTime?, DateTime?)>[];

  @override
  Future<Map<String, dynamic>> getIncomeStatementReport({
    DateTime? startDate,
    DateTime? endDate,
    String groupBy = 'month',
    bool includeUnposted = false,
  }) async {
    asked.add((startDate, endDate));
    Map<String, dynamic> row(
      String key,
      String name, {
      num? cash,
      num? weight,
      String? style,
      int? account,
    }) => {
      'key': key,
      'name': name,
      'cash': cash,
      'weight': weight,
      'style': style,
      'drill': account == null ? null : {'kind': 'account', 'id': account},
    };
    return {
      'id': 'income_statement',
      'title': 'قائمة الدخل',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': null},
      'columns': [
        {'key': 'name', 'label': 'البند', 'kind': 'text'},
        {'key': 'cash', 'label': 'ريال', 'kind': 'money', 'signed': true},
        {'key': 'weight', 'label': 'جم', 'kind': 'grams', 'signed': true},
      ],
      'rows': [
        row('revenue', 'الإيرادات', style: 'heading'),
        row('account_400', 'مبيعات ذهب جديد', cash: 1400313.91, account: 400),
        row('net_profit', 'صافي الربح', cash: 279929.62, style: 'subtotal'),
        row('net_margin', 'هامش صافي الربح 18.89%', style: 'note'),
        row('gram_layers', 'ربح الجرام — الطبقات الخمس', style: 'heading'),
        row('layer_trading', '① المتاجرة', weight: 493.266),
        row(
          'gram_profit',
          'صافي ربح الجرام',
          weight: 530.025,
          style: 'subtotal',
        ),
      ],
      'totals': <String, dynamic>{},
      'checks': [],
      'read_at': '2026-11-04T10:32:00',
    };
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<_Server> _open(WidgetTester tester, {DateTimeRange? range}) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final server = _Server();
  await tester.pumpWidget(
    MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: IncomeStatementReportScreen(
          api: server,
          initialRange: range,
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
    'it opens on the dashboard\'s period; its riyals and grams drawn',
    (tester) async {
      final october = DateTimeRange(
        start: DateTime(2026, 10, 1),
        end: DateTime(2026, 10, 31),
      );
      final server = await _open(tester, range: october);
      expect(server.asked.single, (october.start, october.end));
      expect(find.text('هامش صافي الربح 18.89%'), findsOneWidget);
      expect(find.text('530.025'), findsOneWidget);
    },
  );

  testWidgets('«all» is this year to today', (tester) async {
    final server = await _open(tester);
    expect(server.asked.single, (DateTime(2026, 1, 1), DateTime(2026, 11, 4)));
    await tester.tap(find.byKey(const ValueKey('report-period')));
    await _settle(tester);
    await tester.tap(find.text('كل الفترات').last);
    await _settle(tester);
    expect(server.asked.last, (DateTime(2026, 1, 1), DateTime(2026, 11, 4)));
  });

  testWidgets('an account opens its statement', (tester) async {
    await _open(tester);
    await tester.tap(find.text('مبيعات ذهب جديد'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<AccountStatementScreen>(find.byType(AccountStatementScreen))
          .accountId,
      400,
    );
  });
}
