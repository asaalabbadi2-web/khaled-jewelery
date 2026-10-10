import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/account_tree.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/accounts_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/arabic_search.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The accounts list (the analysis of 10 Oct 2026): 456 accounts flat, in
/// cards of three badges and two balances each; a balance as a bare sign; «0
/// جم» on every cash account; a search blind to «أ/ا» and «١١٠»; the order
/// «عدد الأبناء» sorting by has-children; the view forgotten between visits.

Map<String, dynamic> _account(int id, String number, String name,
        {int? parent, double cash = 0, double gold = 0, bool weight = false, List<int> kids = const []}) =>
    {
      'id': id,
      'account_number': number,
      'name': name,
      'type': 'Asset',
      'parent_id': parent,
      'parent_account': parent == null ? null : {'id': parent},
      'sub_accounts': [for (final k in kids) {'id': k}],
      'tracks_weight': weight,
      'balances': {
        'cash': cash,
        'weight': {'total': gold},
      },
    };

final _accounts = [
  _account(1, '1', 'الأصول', kids: [11, 12]),
  _account(11, '11', 'الأصول المتداولة', parent: 1, kids: [110, 111, 112]),
  _account(110, '110', 'صندوق النقدية', parent: 11, cash: 2500),
  _account(111, '111', 'مؤسسة الذهب', parent: 11, cash: -300),
  _account(112, '112', 'خزينة الذهب', parent: 11, gold: 12.5, weight: true),
  _account(12, '12', 'الأصول الثابتة', parent: 1, kids: [120]),
  _account(120, '120', 'أثاث', parent: 12, cash: 900),
];

class _FakeApi extends ApiService {
  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => _accounts;
}

void main() {
  group('a search reads Arabic as people write it', () {
    test('letter forms, diacritics, tatweel and Arabic-Indic digits', () {
      expect(normalizeForSearch('الأصول'), normalizeForSearch('الاصول'));
      expect(normalizeForSearch('مؤسسة'), 'موسسه');
      expect(normalizeForSearch('إِيـــداع'), 'ايداع');
      expect(normalizeForSearch('١١٠'), '110');
      expect(normalizeForSearch('على'), 'علي');
    });
  });

  group('the chart as a tree', () {
    test('a parent, then its children in number order, each a level deeper', () {
      final rows = accountTreeRows(_accounts, collapsed: {});
      expect([for (final r in rows) '${'-' * r.depth}${r.account['account_number']}'],
          ['1', '-11', '--110', '--111', '--112', '-12', '--120']);
      expect(rows.first.hasChildren, isTrue);
      expect(rows[2].hasChildren, isFalse);
    });

    test('a folded parent hides what is under it', () {
      final rows = accountTreeRows(_accounts, collapsed: {11});
      expect([for (final r in rows) r.account['account_number']], ['1', '11', '12', '120']);
      expect(rows[1].expanded, isFalse);
    });

    test('a filtered-in account keeps its parents, so it is never orphaned', () {
      final rows = accountTreeRows(_accounts,
          collapsed: {}, include: (a) => a['tracks_weight'] == true);
      expect([for (final r in rows) r.account['account_number']], ['1', '11', '112']);
    });

    test('it opens on the roots and their children', () {
      expect(accountTreeDefaultCollapsed(_accounts), {11, 12});
    });
  });

  Future<void> open(WidgetTester tester, {double width = 1400, Map<String, Object> prefs = const {}}) async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
    SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21}), ...prefs});
    tester.view.physicalSize = Size(width, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(textDirection: TextDirection.rtl, child: AccountsScreen(apiService: _FakeApi())),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a wide screen opens compact; a balance says its side; no «0 جم» on a cash account', (tester) async {
    await open(tester);
    expect(find.text('الحساب'), findsOneWidget, reason: 'the compact table\'s header');
    expect(find.text('كشف الحساب'), findsNothing, reason: 'no cards with their buttons');
    expect(find.textContaining('2,500.00'), findsOneWidget);
    expect(find.textContaining('مدين'), findsWidgets);
    expect(find.textContaining('300.00'), findsOneWidget);
    expect(find.textContaining('دائن'), findsWidgets, reason: 'a credit balance reads «دائن», not «-300»');
    expect(find.textContaining('-300'), findsNothing);
    expect(find.textContaining('12.5 جم'), findsOneWidget, reason: 'the weight account\'s gold');
    expect(find.text('0 جم'), findsNothing, reason: 'a cash account shows no gold');
  });

  testWidgets('the search finds «الاصول» for «الأصول» and «١١٢» for 112', (tester) async {
    await open(tester);
    await tester.enterText(find.byType(TextField).first, 'موسسه');
    await tester.pumpAndSettle();
    expect(find.text('مؤسسة الذهب'), findsOneWidget);
    expect(find.text('أثاث'), findsNothing);

    await tester.enterText(find.byType(TextField).first, '١١٢');
    await tester.pumpAndSettle();
    expect(find.text('خزينة الذهب'), findsOneWidget);
  });

  testWidgets('the tree: parents fold and open; the view chosen is kept', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('accounts-view-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('شجرة الحسابات'));
    await tester.pumpAndSettle();

    expect(find.text('الأصول المتداولة'), findsOneWidget);
    expect(find.text('صندوق النقدية'), findsNothing, reason: 'opens on the roots and their children');
    await tester.tap(find.byKey(const Key('account-fold-11')));
    await tester.pumpAndSettle();
    expect(find.text('صندوق النقدية'), findsOneWidget);
    expect(tester.getTopLeft(find.text('صندوق النقدية')).dx,
        isNot(tester.getTopLeft(find.text('الأصول المتداولة')).dx), reason: 'indented under its parent');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('accounts_view_mode'), 'tree');
  });

  testWidgets('a narrow screen opens on cards', (tester) async {
    await open(tester, width: 500);
    expect(find.text('كشف الحساب'), findsWidgets);
  });

  testWidgets('a kept choice wins over the width', (tester) async {
    await open(tester, width: 500, prefs: {'accounts_view_mode': 'compact'});
    expect(find.text('كشف الحساب'), findsNothing);
    expect(find.text('الحساب'), findsOneWidget);
  });

  testWidgets('«عدد الأبناء» orders by how many', (tester) async {
    await open(tester);
    expect(find.text('فلاتر'), findsNothing);
    await tester.tap(find.text('رقم الحساب'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('عدد الأبناء').last);
    await tester.pumpAndSettle();
    // descending: 11 (three children) before 1 (two) before 12 (one)
    await tester.tap(find.text('تصاعدي'));
    await tester.pumpAndSettle();
    double y(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(y('الأصول المتداولة'), lessThan(y('الأصول')));
    expect(y('الأصول'), lessThan(y('الأصول الثابتة')));
  });
}
