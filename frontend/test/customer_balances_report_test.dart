// REPORTS ت5-1 (ADR-083): customers' balances on the reports' shell. The
// journey: it opens on today; a customer's riyals and grams, and what no
// customer holds said apart; the check said; a customer opens its statement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/customer_balances_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final days = <String>[];

  @override
  Future<Map<String, dynamic>> getCustomerBalances({
    required String asOf,
  }) async {
    days.add(asOf);
    return {
      'id': 'customer_balances',
      'title': 'أرصدة العملاء',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': asOf},
      'columns': [
        {'key': 'code', 'label': 'الكود', 'kind': 'text'},
        {'key': 'name', 'label': 'العميل', 'kind': 'text'},
        {
          'key': 'cash',
          'label': 'الرصيد (ريال)',
          'kind': 'money',
          'signed': true,
        },
        {'key': 'gold', 'label': 'الذهب (جم)', 'kind': 'grams', 'signed': true},
      ],
      'rows': [
        {
          'code': 'C-016',
          'name': 'فيصل الحارثي',
          'cash': 2150.0,
          'gold': 0.0,
          'drill': {'kind': 'customer', 'id': 16},
        },
        {
          'name': 'على حسابات العملاء المشتركة بلا عميل',
          'style': 'finding',
          'cash': 75.0,
          'gold': 0.0,
        },
      ],
      'totals': {'cash': 2225.0, 'gold': 0.0},
      'checks': [
        {
          'key': 'every_line_has_its_customer',
          'label': 'كل سطر على حسابات العملاء له عميل',
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
  testWidgets('it opens on today; what no customer holds is apart; a '
      'customer opens its statement', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: CustomerBalancesReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.days.single, '2026-10-31');
    expect(find.text('على حسابات العملاء المشتركة بلا عميل'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('report-check-every_line_has_its_customer')),
      findsOneWidget,
    );
    await tester.tap(find.text('فيصل الحارثي'));
    await _settle(tester);
    final statement = tester.widget<AccountStatementScreen>(
      find.byType(AccountStatementScreen),
    );
    expect((statement.accountId, statement.entityType), (16, 'customer'));
  });
}
