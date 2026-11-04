// REPORTS ت5-3 (ADR-083): the gold safes against the books on the reports'
// shell. The journey: it opens on today; a safe's karats, a difference said
// apart; the check said; a safe opens its account.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/safe_gold_reconciliation_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final days = <String>[];

  @override
  Future<Map<String, dynamic>> getSafeGoldReconciliation({
    required String asOf,
  }) async {
    days.add(asOf);
    return {
      'id': 'safe_gold_reconciliation',
      'title': 'ميزان مراجعة الأوزان (خزنة ↔ حساب)',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': asOf},
      'columns': [
        {'key': 'name', 'label': 'الخزينة / العيار', 'kind': 'text'},
        {'key': 'statement', 'label': 'دفتر الخزينة (جم)', 'kind': 'grams'},
        {'key': 'ledger', 'label': 'الدفاتر (جم)', 'kind': 'grams'},
        {
          'key': 'difference',
          'label': 'الفرق',
          'kind': 'grams',
          'signed': true,
        },
      ],
      'rows': [
        {
          'safe_box_id': 47,
          'name': 'مكتب الراقي - ذهب',
          'style': 'heading',
          'statement': 0.0,
          'ledger': -396.6,
          'difference': 396.6,
          'drill': {'kind': 'account', 'id': 900},
        },
        {
          'safe_box_id': 47,
          'karat': '21k',
          'name': 'عيار 21',
          'statement': 0.0,
          'ledger': -396.6,
          'difference': 396.6,
          'style': 'finding',
        },
      ],
      'totals': {'statement': 0.0, 'ledger': -396.6, 'difference': 396.6},
      'checks': [
        {
          'key': 'statements_agree',
          'label': 'دفتر كل خزينة ذهب = حسابها في الدفاتر (حدّ 0.01 جم)',
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
  testWidgets('it opens on today; a safe opens its account', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SafeGoldReconciliationReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.days.single, '2026-10-31');
    expect(
      find.byKey(const ValueKey('report-check-statements_agree')),
      findsOneWidget,
    );
    await tester.tap(find.text('مكتب الراقي - ذهب'));
    await _settle(tester);
    final statement = tester.widget<AccountStatementScreen>(
      find.byType(AccountStatementScreen),
    );
    expect(statement.accountId, 900);
  });
}
