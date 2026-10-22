import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/suppliers_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/app_state_views.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';
import 'support/shots.dart';

/// The suppliers screen (ADR-050 ر٠): the gold at the main karat is the
/// server's (`balance_gold_main`) -- the screen worked it out with its own
/// formula; deleting says which supplier and what the server will do, and a
/// refusal comes in the server's words, not «Exception: ...».
class _FakeApi extends ApiService {
  _FakeApi({
    required this.rows,
    this.deleteAnswer,
    this.deleteRefusal,
    this.failLoads = 0,
  });

  /// How many of the next loads fail.
  int failLoads;

  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? deleteAnswer;
  final String? deleteRefusal;
  final deleted = <int>[];

  @override
  Future<List<dynamic>> getSuppliers() async {
    if (failLoads > 0) {
      failLoads--;
      throw ApiException.text('انقطع الاتصال بالخادم');
    }
    return rows;
  }

  @override
  Future<Map<String, dynamic>> deleteSupplier(int id) async {
    deleted.add(id);
    final refusal = deleteRefusal;
    if (refusal != null) throw ApiException.text(refusal);
    return deleteAnswer ?? {'result': 'success', 'action': 'deleted'};
  }
}

/// A supplier we owe 10 g of 21k and 7 g of 18k -- 16 g at 21 by the
/// screen's old formula; the server here says 15.5, so the figure shown is
/// visibly the server's.
Map<String, dynamic> _supplier({Object? goldMain = -15.5}) => {
  'id': 5,
  'name': 'مورد الذهب',
  'supplier_code': 'S-000005',
  'active': true,
  'balance_cash': -2500.0,
  'balance_gold_18k': -7.0,
  'balance_gold_21k': -10.0,
  'balance_gold_22k': 0.0,
  'balance_gold_24k': 0.0,
  'balance_gold_main': goldMain,
};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<void> open(
    WidgetTester tester,
    _FakeApi api, {
    ThemeData? theme,
    Size size = const Size(1440, 1600),
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: SuppliersScreen(api: api),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the gold at the main karat', () {
    testWidgets('is the server\'s figure, not one worked out here', (
      tester,
    ) async {
      await open(tester, _FakeApi(rows: [_supplier()]));
      expect(find.textContaining('15.500'), findsWidgets);
      expect(find.textContaining('16.000'), findsNothing);
    });

    testWidgets('without a main karat it is «—», not 0 -- and the supplier '
        'still has a balance', (tester) async {
      await open(tester, _FakeApi(rows: [_supplier(goldMain: null)]));
      expect(find.text('—'), findsWidgets);
      expect(find.textContaining('15.500'), findsNothing);
    });
  });

  group('deleting', () {
    Future<void> askToDelete(WidgetTester tester) async {
      await tester.tap(find.byType(PopupMenuButton<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('حذف/تعطيل').last);
      await tester.pumpAndSettle();
    }

    testWidgets('says which supplier and what happens; going back deletes '
        'nothing', (tester) async {
      final api = _FakeApi(rows: [_supplier()]);
      await open(tester, api);
      await askToDelete(tester);
      expect(find.text('حذف المورد؟'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('مورد الذهب'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('يُعطَّل'), findsOneWidget);
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
      expect(api.deleted, isEmpty);
    });

    testWidgets('a supplier with history is said deactivated', (tester) async {
      final api = _FakeApi(
        rows: [_supplier()],
        deleteAnswer: {'result': 'success', 'action': 'deactivated'},
      );
      await open(tester, api);
      await askToDelete(tester);
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(api.deleted, [5]);
      expect(find.textContaining('عُطِّل المورد «مورد الذهب»'), findsOneWidget);
    });

    testWidgets('a refusal is the server\'s words', (tester) async {
      final api = _FakeApi(
        rows: [_supplier()],
        deleteRefusal: 'لا يمكن حذف مورد لديه رصيد',
      );
      await open(tester, api);
      await askToDelete(tester);
      await tester.tap(find.byKey(const Key('confirm-action')));
      await tester.pumpAndSettle();
      expect(find.textContaining('لا يمكن حذف مورد لديه رصيد'), findsOneWidget);
      expect(find.textContaining('Exception'), findsNothing);
    });
  });

  // ر١ (ADR-057): the app's error and empty views.
  testWidgets('a failed load says the server\'s words, and tries again', (
    tester,
  ) async {
    await open(tester, _FakeApi(rows: [_supplier()], failLoads: 1));
    expect(find.text('تعذّر تحميل الموردين'), findsOneWidget);
    expect(find.text('انقطع الاتصال بالخادم'), findsOneWidget);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('مورد الذهب'), findsWidgets);
  });

  testWidgets('a search that finds nothing offers to clear it', (tester) async {
    await open(tester, _FakeApi(rows: [_supplier()]));
    await tester.enterText(find.byType(TextField).first, 'لا أحد');
    await tester.pumpAndSettle();
    expect(find.text('لا توجد نتائج مطابقة'), findsOneWidget);
    // The empty view's own -- the toolbar has one too.
    await tester.tap(
      find.descendant(
        of: find.byType(AppEmptyView),
        matching: find.text('مسح الفلاتر'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('مورد الذهب'), findsWidgets);
  });

  // ر٢ (ADR-057): the screen reads in the dark theme.
  for (final (name, size) in [
    ('desktop', const Size(1440, 1600)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await open(
        tester,
        _FakeApi(
          rows: [
            _supplier(),
            {..._supplier(), 'id': 6, 'name': 'مورد موقوف', 'active': false},
          ],
        ),
        theme: DarkTheme.theme,
        size: size,
      );
      expect(tester.takeException(), isNull);
      await shot(tester, 'suppliers_dark_$name');
      expectNoTextVanishesOnDark(tester);
      expectNoLightSurfaceOnDark(tester);
    });
  }
}
