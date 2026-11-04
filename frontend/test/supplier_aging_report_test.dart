// REPORTS ت3-2ب (ADR-083): the suppliers' aging on the reports' shell. The
// journey: it opens on today in riyals; «بالجرام» asks for grams; its
// buckets and its check are drawn; a supplier opens its statement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/supplier_aging_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final asked = <(String, String)>[];

  @override
  Future<Map<String, dynamic>> getSupplierAging({
    required String asOf,
    required String dimension,
  }) async {
    asked.add((asOf, dimension));
    final kind = dimension == 'gold' ? 'grams' : 'money';
    return {
      'id': 'supplier_aging',
      'title': 'أعمار ديون الموردين',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': asOf},
      'columns': [
        {'key': 'code', 'label': 'الكود', 'kind': 'text'},
        {'key': 'name', 'label': 'المورد', 'kind': 'text'},
        {'key': 'days_0_30', 'label': 'حالي (0-30)', 'kind': kind},
        {'key': 'days_31_60', 'label': '31-60 يومًا', 'kind': kind},
        {'key': 'days_61_90', 'label': '61-90 يومًا', 'kind': kind},
        {'key': 'over_90', 'label': 'أكثر من 90 يومًا', 'kind': kind},
        {
          'key': 'prepaid',
          'label': 'مدفوع مقدّمًا',
          'kind': kind,
          'signed': true,
        },
        {'key': 'total', 'label': 'الرصيد', 'kind': kind, 'signed': true},
      ],
      'rows': [
        {
          'code': 'S-07',
          'name': 'مورجنايت',
          'days_0_30': 0.0,
          'days_31_60': 24481.0,
          'days_61_90': 0.0,
          'over_90': 0.0,
          'prepaid': 0.0,
          'total': 24481.0,
          'drill': {'kind': 'supplier', 'id': 7},
        },
      ],
      'totals': {'days_31_60': 24481.0, 'total': 24481.0},
      'checks': [
        {
          'key': 'agrees_with_ledger',
          'label': 'رصيد كل مورد = رصيده في الدفتر',
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

void main() {
  testWidgets('it opens on today in riyals; grams on asking; a supplier '
      'opens its statement', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SupplierAgingReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.asked.single, ('2026-10-31', 'cash'));
    expect(
      find.byKey(const ValueKey('report-check-agrees_with_ledger')),
      findsOneWidget,
    );
    expect(find.text('31-60 يومًا'), findsOneWidget);

    await tester.tap(find.text('بالجرام'));
    await _settle(tester);
    expect(server.asked.last, ('2026-10-31', 'gold'));

    await tester.tap(find.text('مورجنايت'));
    await _settle(tester);
    final statement = tester.widget<AccountStatementScreen>(
      find.byType(AccountStatementScreen),
    );
    expect(statement.accountId, 7);
    expect(statement.entityType, 'supplier');
  });
}
