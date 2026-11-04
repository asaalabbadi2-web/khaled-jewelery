// REPORTS ت5-2 (ADR-083): the gold by place on the reports' shell. The
// journey: it opens on today; each place's karats and its main-karat grams
// under its group; the check against the balance sheet said; the value note;
// a place opens its account's statement.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/gold_by_place_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final days = <String>[];

  @override
  Future<Map<String, dynamic>> getGoldByPlace({required String asOf}) async {
    days.add(asOf);
    return {
      'id': 'gold_by_place',
      'title': 'الذهب حسب مكانه',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': asOf},
      'columns': [
        {'key': 'number', 'label': 'الحساب', 'kind': 'text'},
        {'key': 'name', 'label': 'المكان', 'kind': 'text'},
        {'key': 'k21', 'label': 'عيار 21', 'kind': 'grams', 'signed': true},
        {'key': 'main', 'label': 'بعيار 21', 'kind': 'grams', 'signed': true},
      ],
      'rows': [
        {
          'name': 'المخزون',
          'number': '130',
          'style': 'heading',
          'main': 22432.17,
        },
        {
          'account_id': 300,
          'number': '71300',
          'name': 'الذهب المعروض',
          'k21': 15000.0,
          'main': 22356.376,
          'drill': {'kind': 'account', 'id': 300},
        },
        {
          'name':
              'قيمتها بسعر اليوم (416.27 ريال لجرام عيار 21): 17,695,310.58 ريال',
          'style': 'note',
        },
      ],
      'totals': {'k21': 28416.714, 'main': 42509.255},
      'checks': [
        {
          'key': 'the_balance_sheet_s',
          'label': 'المجموع = أصول الميزانية بالوزن',
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
  testWidgets('it opens on today; a place opens its account', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: GoldByPlaceReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.days.single, '2026-10-31');
    expect(
      find.byKey(const ValueKey('report-check-the_balance_sheet_s')),
      findsOneWidget,
    );
    expect(find.textContaining('بسعر اليوم'), findsOneWidget);
    await tester.tap(find.text('الذهب المعروض'));
    await _settle(tester);
    final statement = tester.widget<AccountStatementScreen>(
      find.byType(AccountStatementScreen),
    );
    expect(statement.accountId, 300);
  });
}
