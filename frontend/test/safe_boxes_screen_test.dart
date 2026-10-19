import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/safe_boxes_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'support/dark_text.dart';

/// «إدارة الخزائن» (the analysis of 12 Oct 2026, SAFES-UI-1): the screen
/// summed the safes itself and converted gold with a fixed 21; one «إجمالي
/// النقد» held the drawer, the banks and the card networks; «181698.00»
/// without separators; a «شبكات» tab for a type with no safe while the networks
/// sat under «مستحقات تحصيل»; a card's details behind a 4-pixel strip; three
/// unnamed buttons; 80 fixed colours.

Map<String, dynamic> _safe(
  int id,
  String name,
  String type,
  int accountId,
  String accountNo, {
  double cash = 0,
  Map<String, double>? weight,
  bool isDefault = false,
  bool active = true,
}) => {
  'id': id,
  'name': name,
  'safe_type': type,
  'account_id': accountId,
  'is_active': active,
  'is_default': isDefault,
  'account': {
    'id': accountId,
    'account_number': accountNo,
    'name': 'حساب $name',
    'type': 'Asset',
  },
  'balance': {'cash': cash, if (weight != null) 'weight': weight},
  'pending': {'cash': 0.0, 'weight': {}, 'documents': 0},
};

// The main karat is 22 here: 10 g of 21 is 9.545 g of 22. A screen that
// converts on its own with 21 shows 10.000.
final _overview = {
  'rows': [
    _safe(
      38,
      'خزينة النقدية الرئيسية',
      'cash',
      755,
      '1100000',
      cash: 181698.0,
      isDefault: true,
    ),
    _safe(51, 'صندوق نقدية مؤقت', 'cash', 1152, '1100010', cash: 17093.04),
    _safe(
      37,
      'خزينة بنك الرياض',
      'bank',
      757,
      '1110000',
      cash: 119068.58,
      isDefault: true,
    ),
    _safe(35, 'تمارا', 'clearing', 783, '1120040', cash: 13720.0),
    _safe(
      30,
      'خزينة الذهب المعروض للبيع',
      'gold',
      760,
      '1300000',
      weight: {'18k': 0.0, '21k': 10.0, '22k': 0.0, '24k': 0.0, 'total': 9.545},
    ),
  ],
  'totals': {
    'cash': {'count': 2, 'cash': 198791.04, 'weight_main_karat': 0.0},
    'bank': {'count': 1, 'cash': 119068.58, 'weight_main_karat': 0.0},
    'clearing': {'count': 1, 'cash': 13720.0, 'weight_main_karat': 0.0},
    'gold': {'count': 1, 'cash': 0.0, 'weight_main_karat': 9.545},
  },
  'main_karat': 22,
};

class _FakeApi extends ApiService {
  _FakeApi({this.failFirst = false, this.overview});
  bool failFirst;
  final Map<String, dynamic>? overview;
  final created = <SafeBoxModel>[];
  int loads = 0;

  @override
  Future<SafeBoxesOverview> getSafeBoxesOverview() async {
    loads++;
    if (failFirst) {
      failFirst = false;
      throw Exception('انقطع الاتصال');
    }
    return SafeBoxesOverview.fromJson(overview ?? _overview);
  }

  @override
  Future<Map<int, Map<String, double>>> getStonesBalance({
    int? safeBoxId,
  }) async => {};

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [
    {
      'id': 755,
      'account_number': '1100000',
      'name': 'الصندوق الرئيسي',
      'tracks_weight': false,
    },
    {
      'id': 760,
      'account_number': '1300000',
      'name': 'مخزون الذهب',
      'tracks_weight': true,
    },
    {
      'id': 999,
      'account_number': '1100099',
      'name': 'خزينة موقوفة',
      'tracks_weight': false,
      'is_active': false,
    },
  ];

  @override
  Future<SafeBoxModel> createSafeBox(SafeBoxModel safeBox) async {
    created.add(safeBox);
    return safeBox;
  }
}

Future<_FakeApi> _open(
  WidgetTester tester, {
  double width = 1440,
  ThemeData? theme,
  _FakeApi? api,
}) async {
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({
    'app_settings': jsonEncode({'main_karat': 22}),
  });
  tester.view.physicalSize = Size(width, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final fake = api ?? _FakeApi();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: theme ?? LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: SafeBoxesScreen(api: fake),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

/// Gold held with parties (ADR-051): the server groups an office's or a
/// supplier's gold safe «party_gold», apart from the shop's, and says whose.
Map<String, dynamic> _withParties() => {
  'rows': [
    {..._safe(30, 'خزينة الذهب المعروض للبيع', 'gold', 760, '1300000',
        weight: {'18k': 0.0, '21k': 10.0, '22k': 0.0, '24k': 0.0, 'total': 9.545}), 'group': 'gold'},
    {..._safe(47, 'خزنة مكتب الراقي - ذهب', 'gold', 870, '72100017',
        weight: {'18k': 0.0, '21k': 396.6, '22k': 0.0, '24k': 0.0, 'total': 378.573}),
      'group': 'party_gold', 'party_side': 'ours'},
    {..._safe(41, 'حسابنا بشركة الجنيه العربي', 'gold', 889, '72100001',
        weight: {'18k': 0.0, '21k': -5.0, '22k': 0.0, '24k': 0.0, 'total': -4.773}),
      'group': 'party_gold', 'party_side': 'theirs'},
  ],
  'totals': {
    'gold': {'count': 1, 'cash': 0.0, 'weight_main_karat': 9.545},
    'party_gold': {'count': 2, 'cash': 0.0, 'weight_main_karat': 373.8},
  },
  'main_karat': 22,
};

/// Gold by its kind, as the server groups it after ADR-052: the shop's, the
/// employees' custody, and the offices' deposits.
Map<String, dynamic> _byKind() => {
  'rows': [
    {..._safe(30, 'خزينة الذهب المعروض', 'gold', 760, '71300000',
        weight: {'18k': 0.0, '21k': 10.0, '22k': 0.0, '24k': 0.0, 'total': 10.0}),
      'group': 'gold_shop', 'stock_location': 'showroom'},
    {..._safe(39, 'عهدة ذهب صالح العبادي', 'gold', 874, '713100010',
        weight: {'18k': 0.0, '21k': 2.7, '22k': 0.0, '24k': 0.0, 'total': 2.7}),
      'group': 'gold_custody', 'stock_location': 'custody'},
    {..._safe(60, 'ذهب مودع لدى مكتب الراقي', 'gold', 990, '713301',
        weight: {'18k': 0.0, '21k': 396.6, '22k': 0.0, '24k': 0.0, 'total': 396.6}),
      'group': 'gold_deposit', 'stock_location': 'deposit', 'office_cash': -4000.0},
  ],
  'totals': {
    'gold_shop': {'count': 1, 'cash': 0.0, 'weight_main_karat': 10.0},
    'gold_custody': {'count': 1, 'cash': 0.0, 'weight_main_karat': 2.7},
    'gold_deposit': {'count': 1, 'cash': 0.0, 'weight_main_karat': 396.6},
  },
  'main_karat': 21,
};

void main() {
  testWidgets('gold with parties is its own section, and each says whose the gold is', (tester) async {
    await _open(tester, api: _FakeApi(overview: _withParties()));
    expect(find.byKey(const Key('safes-section-party_gold')), findsOneWidget);
    expect(find.text('ذهب لدى الأطراف'), findsWidgets);
    expect(find.byKey(const Key('safes-tile-party_gold')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('safe-party-side-47')), matching: find.text('لنا')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('safe-party-side-41')), matching: find.text('علينا')),
        findsOneWidget);
    expect(find.byKey(const Key('safe-party-side-30')), findsNothing);   // the shop's gold is no party's
  });

  testWidgets('gold is shown by its kind, as the banks are apart from the drawer (ADR-052)', (tester) async {
    await _open(tester, api: _FakeApi(overview: _byKind()));
    for (final (group, label) in [
      ('gold_shop', 'ذهب المحل'),
      ('gold_custody', 'عهد الذهب'),
      ('gold_deposit', 'ذهب مودع لدى المكاتب'),
    ]) {
      expect(find.byKey(Key('safes-section-$group')), findsOneWidget, reason: label);
      expect(find.byKey(Key('safes-tile-$group')), findsOneWidget, reason: label);
      expect(find.text(label), findsWidgets);
    }
    final shop = tester.getTopLeft(find.byKey(const Key('safes-section-gold_shop'))).dy;
    final deposit = tester.getTopLeft(find.byKey(const Key('safes-section-gold_deposit'))).dy;
    expect(shop, lessThan(deposit), reason: 'the shop\'s gold first');
    expect(find.byKey(const Key('safe-party-side-60')), findsNothing, reason: 'a deposit is ours: no «لنا/علينا»');
  });

  testWidgets('a deposit says what is owed to its office, beside its gold (ADR-052, option A)', (tester) async {
    await _open(tester, api: _FakeApi(overview: _byKind()));
    final pill = find.byKey(const Key('safe-office-cash-60'));
    expect(pill, findsOneWidget);
    expect(find.descendant(of: pill, matching: find.textContaining('مستحق للمكتب')), findsOneWidget);
    expect(find.descendant(of: pill, matching: find.textContaining('4,000.00')), findsOneWidget);
    expect(find.byKey(const Key('safe-office-cash-30')), findsNothing, reason: 'the shop\'s gold has no office');
  });

  testWidgets('a section whose safes are all stopped is not shown', (tester) async {
    final overview = _byKind();
    (overview['rows'] as List).add({
      ..._safe(47, 'خزنة مكتب الراقي - ذهب', 'gold', 870, '72100017',
          weight: {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0, 'total': 0.0}),
      'group': 'party_gold', 'party_side': 'settled', 'is_active': false,
    });
    (overview['totals'] as Map)['party_gold'] = {'count': 1, 'cash': 0.0, 'weight_main_karat': 0.0};
    await _open(tester, api: _FakeApi(overview: overview));
    expect(find.byKey(const Key('safes-section-party_gold')), findsNothing);
    expect(find.byKey(const Key('safes-tile-party_gold')), findsNothing);
    expect(find.byKey(const Key('safes-section-gold_deposit')), findsOneWidget);
  });

  testWidgets('a safe made in the deposits section starts at «مودع لدى مكتب»', (tester) async {
    await _open(tester, api: _FakeApi(overview: _byKind()));
    await tester.tap(find.byKey(const Key('safes-tile-gold_deposit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: find.byKey(const Key('safe-form-place')), matching: find.text('مودع لدى مكتب')),
      findsOneWidget,
    );
  });

  test('a party\'s gold is a section, not a type a safe is created as', () {
    expect(safeTypeLabels.containsKey('party_gold'), isFalse);
    expect(safeGroupLabels['party_gold'], 'ذهب لدى الأطراف');
  });

  testWidgets(
    'the summary is the server\'s, one tile per type, the gold in the main karat',
    (tester) async {
      await _open(tester);
      final summary = find.byKey(const Key('safes-summary'));
      expect(
        find.descendant(of: summary, matching: find.text('النقدية')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.text('البنوك')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.text('الشبكات')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: summary, matching: find.text('الذهب')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: summary,
          matching: find.textContaining('198,791.04'),
        ),
        findsOneWidget,
        reason:
            'the drawer alone, with separators -- not the drawer, banks and networks summed',
      );
      expect(
        find.textContaining('9.545'),
        findsWidgets,
        reason: 'the server\'s grams in the main karat',
      );
      expect(
        find.textContaining('10.000 جم'),
        findsNothing,
        reason: 'not converted on the device with 21',
      );
      expect(find.textContaining('إجمالي النقد'), findsNothing);
      expect(
        find.text('شبكات'),
        findsNothing,
        reason: 'no tab for a type with no safe',
      );
      expect(find.textContaining('شيكات'), findsNothing);
      expect(find.textContaining('مستحقات تحصيل'), findsNothing);
    },
  );

  testWidgets(
    '«الكل» groups the safes under their type; a tile shows its type alone',
    (tester) async {
      await _open(tester);
      expect(find.byKey(const Key('safes-section-cash')), findsOneWidget);
      expect(find.byKey(const Key('safes-section-gold')), findsOneWidget);
      expect(find.text('تمارا'), findsOneWidget);

      await tester.tap(find.byKey(const Key('safes-tile-gold')));
      await tester.pumpAndSettle();
      expect(find.text('خزينة الذهب المعروض للبيع'), findsOneWidget);
      expect(find.text('تمارا'), findsNothing);
      expect(find.text('خزينة النقدية الرئيسية'), findsNothing);
    },
  );

  testWidgets(
    'a card names its actions and opens its details where it is tapped',
    (tester) async {
      await _open(tester);
      final card = find.byKey(const Key('safe-card-38'));
      expect(
        find.descendant(of: card, matching: find.text('إضافة')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('سحب')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.text('تحويل')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: card, matching: find.textContaining('181,698.00')),
        findsOneWidget,
      );
      expect(
        find.textContaining('1100000'),
        findsNothing,
        reason: 'the details start folded',
      );

      await tester.tap(
        find.descendant(
          of: card,
          matching: find.text('خزينة النقدية الرئيسية'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('1100000'),
        findsOneWidget,
        reason: 'its account, by tapping the card',
      );
    },
  );

  testWidgets('a failed load says so and tries again', (tester) async {
    await _open(tester, api: _FakeApi(failFirst: true));
    expect(find.textContaining('انقطع الاتصال'), findsOneWidget);
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(find.text('خزينة النقدية الرئيسية'), findsOneWidget);
  });

  testWidgets(
    'a new safe: its account searched as people write it, no karat the server ignores, no creator sent',
    (tester) async {
      final api = await _open(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('العيار'),
        findsNothing,
        reason: 'the server keeps gold safes multi-karat',
      );

      await tester.enterText(
        find.byKey(const Key('safe-form-name')),
        'درج المعرض',
      );
      await tester.enterText(
        find.byKey(const Key('safe-form-account')),
        'الصندوق الرييسي',
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('خزينة موقوفة'),
        findsNothing,
        reason: 'a stopped account is not offered',
      );
      await tester.tap(find.textContaining('الصندوق الرئيسي').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();

      expect(api.created, hasLength(1));
      expect(api.created.single.accountId, 755);
      expect(
        api.created.single.createdBy,
        isNull,
        reason: 'the server knows who is signed in',
      );
    },
  );

  group('a new gold safe says where its gold is (ADR-051)', () {
    Future<_FakeApi> fill(WidgetTester tester) async {
      final api = await _open(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('ذهب').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('safe-form-name')),
        'خزنة مكتب',
      );
      await tester.enterText(
        find.byKey(const Key('safe-form-account')),
        'مخزون الذهب',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('مخزون الذهب').last);
      await tester.pumpAndSettle();
      return api;
    }

    Future<void> choose(WidgetTester tester, String label) async {
      await tester.tap(find.byKey(const Key('safe-form-place')));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
    }

    testWidgets('not said, nothing is sent', (tester) async {
      final api = await fill(tester);
      await tester.tap(find.text('إضافة').last);
      await tester.pumpAndSettle();
      expect(api.created, isEmpty);
      expect(find.text('حدّد مكان الذهب'), findsOneWidget);
    });

    testWidgets('«لدى طرف» is sent as no stock location', (tester) async {
      final api = await fill(tester);
      await choose(tester, 'لدى طرف (مكتب أو مورد)');
      final sent = api.created.single.toJson();
      expect(sent.containsKey('stock_location'), isTrue);
      expect(sent['stock_location'], isNull);
    });

    testWidgets('«معروض» is the showroom', (tester) async {
      final api = await fill(tester);
      await choose(tester, 'معروض');
      expect(api.created.single.toJson()['stock_location'], 'showroom');
    });
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets(
      'dark theme at $width: lays out, the text on the theme\'s surface',
      (tester) async {
        await _open(tester, width: width, theme: DarkTheme.theme);
        expect(tester.takeException(), isNull);
        final name = tester.widget<Text>(find.text('خزينة النقدية الرئيسية'));
        final style = DefaultTextStyle.of(
          tester.element(find.text('خزينة النقدية الرئيسية')),
        ).style.merge(name.style);
        final onSurface = DarkTheme.theme.colorScheme.onSurface;
        expect(
          style.color,
          onSurface,
          reason: 'not a fixed near-black on a dark card',
        );
        expectNoTextVanishesOnDark(tester);
        expectNoLightSurfaceOnDark(tester);
      },
    );
  }

  // خ٤ (ADR-050): the keys of every list -- Ctrl+F to search, F5 to load.
  testWidgets('Ctrl+F puts the cursor in the search; F5 loads again', (
    tester,
  ) async {
    final api = await _open(tester);
    final loads = api.loads;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    final search = tester.widget<TextField>(
      find.widgetWithText(TextField, 'ابحث باسم الخزينة أو الحساب أو رقمه'),
    );
    expect(search.focusNode?.hasFocus, isTrue);

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.f5);
    await tester.pumpAndSettle();
    expect(api.loads, loads + 1);
  });
}
