import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/customers_screen.dart';
import 'package:frontend/screens/suppliers_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

/// The owner (17 Nov 2026): «طريقة عرض قائمة الموردين والعملاء في الشاشات
/// العريضة تحتاج تطوير». A card a party, the width of the screen: three
/// suppliers in sight at 1920, their balances far from their names. Now a
/// table on a wide screen -- a row a party, its balances said «له» or «عليه»
/// side by side, sorted from the header -- and cards on a phone. The
/// customers' list had less: no summary, no filters, a minus sign for «له»,
/// «4150.00» with no thousands, a gold of its own formula, and a list that
/// did not load said «لا يوجد عملاء».
class _Customers extends ApiService {
  _Customers(this.rows, {this.fail = false});

  final List<Map<String, dynamic>> rows;
  final bool fail;

  @override
  Future<List<dynamic>> getCustomers() async {
    if (fail) throw ApiException.text('انقطع الاتصال بالخادم');
    return rows;
  }
}

class _Suppliers extends ApiService {
  _Suppliers(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  Future<List<dynamic>> getSuppliers() async => rows;
}

Map<String, dynamic> _customer(int id, String name, {double cash = 0, double gold21 = 0, Object? goldMain, bool active = true}) => {
  'id': id,
  'name': name,
  'customer_code': 'C-${id.toString().padLeft(6, '0')}',
  'phone': '05$id',
  'active': active,
  'balance_cash': cash,
  'balance_gold_18k': 0.0,
  'balance_gold_21k': gold21,
  'balance_gold_22k': 0.0,
  'balance_gold_24k': 0.0,
  'balance_gold_main': goldMain ?? gold21,
};

final _three = [
  _customer(1, 'أحمد', cash: 4150.0),
  _customer(2, 'بدر', cash: -1660.0, gold21: 2.0, goldMain: 2.0),
  _customer(3, 'جود'),
];

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<void> open(WidgetTester tester, Widget screen, {double width = 1600, ThemeData? theme}) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: Directionality(textDirection: TextDirection.rtl, child: screen),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  List<String> namesInOrder(WidgetTester tester, List<String> names) {
    final found = [
      for (final n in names)
        if (find.text(n).evaluate().isNotEmpty) (n, tester.getTopLeft(find.text(n).first).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final (n, _) in found) n];
  }

  group('the customers', () {
    testWidgets('a wide screen: a table, the balances said «له» and «عليه», '
        'the thousands separated, no minus sign', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three)));
      expect(find.byKey(const Key('app-table')), findsOneWidget);
      expect(find.byKey(const Key('party-row-2')), findsOneWidget);
      expect(find.textContaining('4,150.00'), findsWidgets);
      expect(find.textContaining('1,660.00'), findsWidgets);
      expect(find.textContaining('-1660'), findsNothing);
      expect(find.text('عليه'), findsWidgets);
      expect(find.text('له'), findsWidgets);
    });

    testWidgets('a phone: cards, not a table', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three)), width: 390);
      expect(find.byKey(const Key('app-table')), findsNothing);
      expect(find.byType(Card), findsWidgets);
      expect(find.text('أحمد'), findsOneWidget);
    });

    testWidgets('the gold at the main karat is the server\'s, not a formula '
        'of the screen\'s', (tester) async {
      // 10 g of 21 by the server at 9.5 -- the screen had its own sum.
      await open(tester, CustomersScreen(api: _Customers([_customer(1, 'أحمد', gold21: 10.0, goldMain: 9.5)])));
      expect(find.textContaining('9.500'), findsWidgets);
      expect(find.textContaining('10.000'), findsNothing);
    });

    testWidgets('the header sorts: by cash, then the other way', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three)));
      expect(namesInOrder(tester, ['أحمد', 'بدر', 'جود']), ['أحمد', 'بدر', 'جود']);
      await tester.tap(find.byKey(const Key('party-sort-cash')));
      await tester.pumpAndSettle();
      expect(namesInOrder(tester, ['أحمد', 'بدر', 'جود']), ['بدر', 'جود', 'أحمد']);
      await tester.tap(find.byKey(const Key('party-sort-cash')));
      await tester.pumpAndSettle();
      expect(namesInOrder(tester, ['أحمد', 'بدر', 'جود']), ['أحمد', 'جود', 'بدر']);
    });

    testWidgets('the suppliers\' filters: with a balance, active', (tester) async {
      await open(tester, CustomersScreen(api: _Customers([..._three, _customer(4, 'دانة', cash: 5.0, active: false)])));
      expect(find.text('جود'), findsOneWidget);
      await tester.tap(find.byKey(const Key('customers-with-balance')));
      await tester.pumpAndSettle();
      expect(find.text('جود'), findsNothing);
      expect(find.text('دانة'), findsOneWidget);
      await tester.tap(find.byKey(const Key('customers-only-active')));
      await tester.pumpAndSettle();
      expect(find.text('دانة'), findsNothing);
      expect(find.text('أحمد'), findsOneWidget);
    });

    testWidgets('what stands is summed above: owed to us and owed by us', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three)));
      expect(find.byKey(const Key('customers-summary-line')), findsOneWidget);
      final line = find.byKey(const Key('customers-summary-line'));
      expect(find.descendant(of: line, matching: find.textContaining('علينا لهم')), findsWidgets);
      expect(find.descendant(of: line, matching: find.textContaining('1,660.00')), findsOneWidget);
      expect(find.descendant(of: line, matching: find.textContaining('4,150.00')), findsOneWidget);
    });

    testWidgets('a list that did not load says so, in the server\'s words -- '
        'not «لا يوجد عملاء»', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three, fail: true)));
      expect(find.text('تعذّر تحميل العملاء'), findsOneWidget);
      expect(find.text('انقطع الاتصال بالخادم'), findsOneWidget);
      expect(find.textContaining('لا يوجد عملاء'), findsNothing);
    });

    testWidgets('the delete is in the menu, not a button beside the others', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three)));
      expect(find.byIcon(Icons.delete), findsNothing);
      await tester.tap(find.byKey(const Key('customer-menu-1')).first);
      await tester.pumpAndSettle();
      expect(find.text('حذف'), findsOneWidget);
    });
  });

  group('the suppliers', () {
    Map<String, dynamic> supplier(int id, String name, double cash) => {
      'id': id,
      'name': name,
      'supplier_code': 'S-$id',
      'active': true,
      'balance_cash': cash,
      'balance_gold_18k': 0.0,
      'balance_gold_21k': 0.0,
      'balance_gold_22k': 0.0,
      'balance_gold_24k': 0.0,
      'balance_gold_main': 0.0,
    };

    testWidgets('a wide screen opens on the table, the summary on one line', (tester) async {
      await open(tester, SuppliersScreen(api: _Suppliers([supplier(1, 'مورد', -2500)])));
      expect(find.byKey(const Key('app-table')), findsOneWidget);
      expect(find.byKey(const Key('suppliers-summary-line')), findsOneWidget);
      expect(find.text('له'), findsWidgets);
    });

    testWidgets('a phone opens on the cards', (tester) async {
      await open(tester, SuppliersScreen(api: _Suppliers([supplier(1, 'مورد', -2500)])), width: 390);
      expect(find.byKey(const Key('app-table')), findsNothing);
    });
  });

  for (final (name, width) in [('wide', 1600.0), ('phone', 390.0)]) {
    testWidgets('both read in the dark, $name: text and icons', (tester) async {
      await open(tester, CustomersScreen(api: _Customers(_three)), width: width, theme: DarkTheme.theme);
      expect(tester.takeException(), isNull);
      expectNoTextVanishesOnDark(tester);
      await open(
        tester,
        SuppliersScreen(api: _Suppliers([
          {..._three.first, 'supplier_code': 'S-1', 'balance_gold_main': 1.0},
        ])),
        width: width,
        theme: DarkTheme.theme,
      );
      expect(tester.takeException(), isNull);
      expectNoTextVanishesOnDark(tester);
    });
  }
}
