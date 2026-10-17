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
  _FakeApi({this.failFirst = false});
  bool failFirst;
  final created = <SafeBoxModel>[];

  @override
  Future<SafeBoxesOverview> getSafeBoxesOverview() async {
    if (failFirst) {
      failFirst = false;
      throw Exception('انقطع الاتصال');
    }
    return SafeBoxesOverview.fromJson(_overview);
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

void main() {
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
}
