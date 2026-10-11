import 'dart:convert';

import 'package:flutter/gestures.dart';
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

/// The chart as production has it (12 Oct 2026): the financial roots 1–5 and
/// their weight twins 71–75, a financial leaf pointing at its weight twin.
/// Built fresh per test -- the screen annotates the maps it is given.
List<Map<String, dynamic>> _withWeightChart() => [
      for (final a in _accounts) {...a, if (a['id'] == 110) 'memo_account_id': 7110},
      _account(7, '71', 'الأصول وزني', weight: true, kids: [711]),
      _account(711, '711', 'الأصول المتداولة وزني', parent: 7, weight: true, kids: [7110]),
      _account(7110, '7110', 'صندوق النقدية وزني', parent: 711, weight: true, gold: 3.25),
    ];

class _FakeApi extends ApiService {
  _FakeApi([this.accounts]);
  final List<Map<String, dynamic>>? accounts;
  final activeCalls = <(int, bool)>[];

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => accounts ?? _accounts;

  @override
  Future<Map<String, dynamic>> setAccountActive(int id, bool active) async {
    activeCalls.add((id, active));
    return {'id': id, 'is_active': active};
  }

  final added = <Map<String, dynamic>>[];
  final deleted = <(int, bool?)>[];
  int loads = 0;

  @override
  Future<Map<String, dynamic>> getNextAccountNumber(String parentNumber) async =>
      {'suggested_number': '${parentNumber}3', 'parent_has_parallel': false};

  @override
  Future<Map<String, dynamic>> validateAccountNumber(
          {required String accountNumber, String? parentAccountNumber, int? excludeAccountId}) async =>
      {'is_valid': true};

  @override
  Future<Map<String, dynamic>> addAccount(Map<String, dynamic> accountData) async {
    added.add(accountData);
    return {'id': 999};
  }

  @override
  Future<Map<String, dynamic>> deleteAccount(int id, {bool? deleteParallel}) async {
    deleted.add((id, deleteParallel));
    return deleteParallel == null
        ? {'result': 'confirm_required', 'parallel_account': {'id': 7120, 'account_number': '7120', 'name': 'أثاث وزني'}}
        : {'result': 'success'};
  }
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

  Future<void> open(WidgetTester tester,
      {double width = 1400, Map<String, Object> prefs = const {}, _FakeApi? api, bool onTree = false}) async {
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
        home: Directionality(
            textDirection: TextDirection.rtl, child: AccountsScreen(apiService: api ?? _FakeApi(), openOnTree: onTree)),
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
    await tester.tap(find.text('عرض شجري'));
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

  testWidgets('a deactivated account says so; deactivating asks, then calls the server (ADR-043)', (tester) async {
    final api = _FakeApi([
      ..._accounts,
      {..._account(113, '113', 'ضريبة مستحقة قديمة', parent: 11), 'is_active': false},
    ]);
    await open(tester, api: api);
    expect(find.textContaining('موقوف'), findsOneWidget, reason: 'only the deactivated account is marked');

    await tester.tap(find.byKey(const Key('account-menu-110')));
    await tester.pumpAndSettle();
    expect(find.text('إيقاف الحساب'), findsOneWidget);
    await tester.tap(find.text('إيقاف الحساب'));
    await tester.pumpAndSettle();
    expect(api.activeCalls, isEmpty, reason: 'nothing before the confirmation');
    await tester.tap(find.byKey(const Key('account-active-confirm')));
    await tester.pumpAndSettle();
    expect(api.activeCalls, [(110, false)]);

    await tester.tap(find.byKey(const Key('account-menu-113')));
    await tester.pumpAndSettle();
    expect(find.text('تفعيل الحساب'), findsOneWidget, reason: 'a deactivated account offers activation');
  });

  // ── CHART-UI-1: one accounts screen ──────────────────────────────────────

  testWidgets('a parent shows the server\'s balance -- its own and all under it', (tester) async {
    final api = _FakeApi([
      for (final a in _accounts)
        a['id'] == 11 ? {...a, 'subtree_balances': {'cash': 98765.0, 'weight_total': 12.5}} : a,
    ]);
    await open(tester, api: api);
    expect(find.textContaining('98,765.00'), findsOneWidget, reason: 'the subtree, not the parent\'s own 0');
  });

  testWidgets('the type in Arabic, and a filter by it', (tester) async {
    final api = _FakeApi([..._accounts, {..._account(130, '130', 'مصروف إيجار', parent: 1), 'type': 'expense'}]);
    await open(tester, api: api);
    expect(find.textContaining('أصول'), findsWidgets, reason: 'Asset reads أصول');
    await tester.tap(find.byKey(const Key('accounts-type-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مصروفات').last);
    await tester.pumpAndSettle();
    expect(find.text('مصروف إيجار'), findsOneWidget, reason: 'any spelling of the type');
    expect(find.text('صندوق النقدية'), findsNothing);
  });

  testWidgets('a child account is added from its parent\'s menu, its number the server\'s', (tester) async {
    final api = _FakeApi();
    await open(tester, api: api);
    await tester.tap(find.byKey(const Key('account-menu-11')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إضافة حساب فرعي'));
    await tester.pumpAndSettle();
    expect(find.text('113'), findsOneWidget, reason: 'the suggested number');
    await tester.enterText(find.byKey(const Key('account-form-name')), 'حساب جديد');
    await tester.tap(find.byKey(const Key('account-form-save')));
    await tester.pumpAndSettle();
    expect(api.added.single['parent_id'], 11);
    expect(api.added.single['account_number'], '113');
    expect(api.added.single['type'], 'Asset');
  });

  testWidgets('a delete asks, then asks about the parallel account', (tester) async {
    final api = _FakeApi();
    await open(tester, api: api);
    await tester.tap(find.byKey(const Key('account-menu-120')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف').last);
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty, reason: 'nothing before the confirmation');
    await tester.tap(find.byKey(const Key('account-delete-confirm')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-delete-only-this')));
    await tester.pumpAndSettle();
    expect(api.deleted.map((d) => d.$2).toList(), [null, false]);
  });

  testWidgets('«دليل الحسابات» from the home opens the one screen on its tree', (tester) async {
    await open(tester, onTree: true);
    expect(find.text('دليل الحسابات'), findsWidgets);
    expect(find.byKey(const Key('account-fold-11')), findsOneWidget, reason: 'the tree\'s fold control');
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

  // ── CHART-UI-2: what «شجرة الحسابات» had and the merge left behind ──
  // The owner (12 Oct 2026): «في شجرة الحسابات كان هناك ميزات كان يجب ترحيلها
  // للشاشة الجديدة من ضمنها فاصل واضح بين الحسابات المالية والوزنية».

  Finder row(int id) => find.byKey(Key('account-row-$id'));

  testWidgets('the tree in two sections: the financial in riyals, the weight in grams, each whole', (tester) async {
    await open(tester, onTree: true, api: _FakeApi(_withWeightChart()));
    expect(find.text('الحسابات المالية (بالريال)'), findsOneWidget);
    expect(find.text('الحسابات الوزنية (بالجرام)'), findsOneWidget);
    expect(tester.getTopLeft(find.byKey(const Key('accounts-section-weight'))).dy,
        greaterThan(tester.getTopLeft(find.text('الأصول الثابتة')).dy), reason: 'after the whole financial chart');

    await tester.tap(find.byKey(const Key('accounts-expand-all')));
    await tester.pumpAndSettle();
    expect(row(7110), findsOneWidget, reason: 'a weight twin is in its own chart, not folded into its financial one');
    expect(find.descendant(of: row(7110), matching: find.textContaining('3.25 جم')), findsOneWidget);
    expect(find.descendant(of: row(7110), matching: find.textContaining('ر.س')), findsNothing,
        reason: 'a weight account in grams only');
    expect(find.descendant(of: row(110), matching: find.textContaining('جم')), findsNothing,
        reason: 'a financial account in riyals only');
    expect(find.descendant(of: row(110), matching: find.byTooltip('كشف الحساب الوزني المرتبط')), findsOneWidget);
  });

  testWidgets('a section folds; «توسيع الكل» and «طي الكل»', (tester) async {
    await open(tester, onTree: true, api: _FakeApi(_withWeightChart()));
    expect(find.text('الأصول وزني'), findsOneWidget);
    await tester.tap(find.byKey(const Key('accounts-section-weight')));
    await tester.pumpAndSettle();
    expect(find.text('الأصول وزني'), findsNothing);
    await tester.tap(find.byKey(const Key('accounts-section-weight')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('accounts-expand-all')));
    await tester.pumpAndSettle();
    expect(find.text('صندوق النقدية'), findsOneWidget);
    expect(find.text('صندوق النقدية وزني'), findsOneWidget);
    await tester.tap(find.byKey(const Key('accounts-collapse-all')));
    await tester.pumpAndSettle();
    expect(find.text('الأصول المتداولة'), findsNothing, reason: 'the roots alone');
    expect(find.text('الأصول'), findsOneWidget);
  });

  testWidgets('the list has the two sections too, and says how many of all it shows', (tester) async {
    await open(tester, api: _FakeApi(_withWeightChart()));
    expect(find.byKey(const Key('accounts-section-financial')), findsOneWidget);
    expect(find.byKey(const Key('accounts-section-weight')), findsOneWidget);
    expect(row(7110), findsOneWidget);
    expect(find.text('المعروض: 10 من 10'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'وزني');
    await tester.pumpAndSettle();
    expect(find.text('المعروض: 3 من 10'), findsOneWidget);
  });

  testWidgets('the search marks what it found in the name', (tester) async {
    await open(tester, api: _FakeApi(_withWeightChart()));
    await tester.enterText(find.byType(TextField).first, 'النقديه');
    await tester.pumpAndSettle();
    bool marks(Widget w) {
      if (w is! RichText) return false;
      var found = false;
      w.text.visitChildren((span) {
        if (span is TextSpan && span.text == 'النقدية' && span.style?.backgroundColor != null) found = true;
        return true;
      });
      return found;
    }

    expect(find.byWidgetPredicate(marks), findsWidgets, reason: '«النقدية» marked for «النقديه»');
  });

  testWidgets('a parent tapped shows its path; «إظهار في الشجرة» finds a searched account there', (tester) async {
    await open(tester, onTree: true, api: _FakeApi(_withWeightChart()));
    await tester.tap(find.text('الأصول المتداولة'));
    await tester.pumpAndSettle();
    final path = find.byKey(const Key('accounts-path'));
    expect(find.descendant(of: path, matching: find.text('الأصول')), findsOneWidget);
    expect(find.descendant(of: path, matching: find.text('الأصول المتداولة')), findsOneWidget);
    expect(find.text('صندوق النقدية'), findsOneWidget, reason: 'a parent tapped opens');

    await tester.enterText(find.byType(TextField).first, 'خزينة');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('account-menu-112')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('إظهار في الشجرة'));
    await tester.pumpAndSettle();
    expect(find.descendant(of: path, matching: find.text('خزينة الذهب')), findsOneWidget);
    expect(row(112), findsOneWidget);
    expect(row(12), findsOneWidget, reason: 'the whole tree again, not the search');
  });

  testWidgets('a pointer over a row shows its actions; its menu stays where it was', (tester) async {
    await open(tester, onTree: true, api: _FakeApi(_withWeightChart()));
    final add = find.descendant(of: row(11), matching: find.byTooltip('إضافة حساب فرعي'));
    expect(add.hitTestable(), findsNothing);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(row(11)));
    await tester.pumpAndSettle();
    expect(add.hitTestable(), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-menu-11')));
    await tester.pumpAndSettle();
    expect(find.text('دفتر الأستاذ'), findsOneWidget, reason: 'the menu works under the pointer');
  });
}
