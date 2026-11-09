// An office's statement says the gold it holds for us (ADR-052; the owner,
// 9 Nov 2026): «ذهبنا عنده» and «رصيد العهدة» beside the trade, the
// custody's closing in its own summary -- and printed. A party with no
// deposit: no such column.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/account_statement_model.dart';
import 'package:frontend/pdf/account_statement_pdf_builder.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _row(int id, String day, String what,
        {double goldCredit = 0, double custody = 0, required double runningCustody, bool only = false}) =>
    {
      'id': id, 'date': '${day}T10:00:00', 'description': what, 'journal_entry_id': id,
      'entry_number': 'JE-$id', 'cash_debit': 0.0, 'cash_credit': 0.0, 'gold_debit': 0.0,
      'gold_credit': goldCredit, 'running_cash_balance': 0.0, 'running_gold_balance': -goldCredit,
      'custody_by_karat': {'21k': custody}, 'custody_main': custody,
      'running_custody_by_karat': {'21k': runningCustody}, 'running_custody_main': runningCustody,
      if (only) 'custody_only': true,
    };

Map<String, dynamic> _statement({bool custody = true}) => {
      'opening_balance_cash': 0.0, 'opening_balance_gold_normalized': 0.0,
      'closing_balance_cash': 0.0, 'closing_balance_gold_normalized': 0.0, 'main_karat': 21,
      'totals': {'cash_debit': 0.0, 'cash_credit': 0.0, 'gold_debit_normalized': 0.0, 'gold_credit_normalized': 0.0},
      'lines': [
        _row(1, '2026-10-19', 'نقل ذهبنا إلى الوديعة', custody: 396.6, runningCustody: 396.6),
        _row(2, '2026-11-06', 'تحويل إلى المعروض', custody: -1.0, runningCustody: 395.6, only: true),
      ],
      if (custody)
        'custody': {
          'safe_box_id': 61, 'name': 'ذهب مودع لدى مكتب الراقي', 'opening_main': 0.0, 'closing_main': 395.6,
          'opening_by_karat': {'21k': 0.0}, 'closing_by_karat': {'18k': 0.0, '21k': 395.6, '22k': 0.0, '24k': 0.0},
        },
    };

class _Api extends ApiService {
  _Api({this.custody = true});
  final bool custody;

  @override
  Future<Map<String, dynamic>> getSupplierStatement(int supplierId, {bool includeCancelled = false}) async =>
      jsonDecode(jsonEncode(_statement(custody: custody))) as Map<String, dynamic>;
}

Future<void> _open(WidgetTester tester, _Api api) async {
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
  tester.view.physicalSize = const Size(1800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: settings,
    child: MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: AccountStatementScreen(accountId: 17, accountName: 'مكتب الراقي', entityType: 'supplier', apiService: api),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an office\'s statement shows the gold it holds for us, row by row and closing', (tester) async {
    await _open(tester, _Api());
    expect(find.text('ذهبنا عنده'), findsOneWidget);
    expect(find.text('رصيد العهدة'), findsOneWidget);
    expect(find.byKey(const Key('summary-custody')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('summary-custody')), matching: find.textContaining('395.6')),
        findsWidgets);
    expect(find.textContaining('ذهب مودع لدى مكتب الراقي'), findsOneWidget);
  });

  testWidgets('a party with no deposit has no custody column', (tester) async {
    await _open(tester, _Api(custody: false));
    expect(find.text('ذهبنا عنده'), findsNothing);
    expect(find.byKey(const Key('summary-custody')), findsNothing);
  });

  test('the custody is read as the server sent it', () {
    final s = AccountStatement.fromJson(_statement());
    expect((s.custody!.closingMain, s.custody!.closingByKarat['21k']), (395.6, 395.6));
    expect(s.lines.map((l) => (l.custodyMain, l.runningCustodyMain, l.custodyOnly)).toList(),
        [(396.6, 396.6, false), (-1.0, 395.6, true)]);
  });

  test('it prints', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final s = AccountStatement.fromJson(_statement());
    final bytes = await AccountStatementPdfBuilder.build(
      pdf.PdfPageFormat.a4,
      statement: s, tableLines: s.lines, accountName: 'مكتب الراقي', accountId: 17, viewMode: 0,
      includeValuation: true, dateRange: null, filterType: 'all', showOnlyMovement: false,
      branding: const AccountStatementPdfBranding(companyName: 'مجوهرات', companyAddress: '', companyPhone: '',
          companyVat: '', companyCr: '', showCompanyLogo: false, companyLogoBase64: ''),
    );
    expect(bytes.length, greaterThan(1000));
  });
}
