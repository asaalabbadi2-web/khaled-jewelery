// «المحاسبة والاعتماد» in the center (settings spec v2, phase 7, batch 5):
// the voucher auto-post is only shown until the owner's decision D2 -- set
// where it was, opened from here; the wage treatment changed alone through
// its confirmation, each way said, with the wage inventory's balance and the
// entry that zeroes it read when the change is asked (ADR-039); the
// accountant's limits and the gold tolerance saved from the bar within the
// server's bounds; nothing overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/settings/section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  final saved = <(Map<String, dynamic>, Map<String, int>, String?)>[];
  bool wageFails = false;
  double wageBalance = 1234.5;

  final settings = <String, dynamic>{
    'voucher_auto_post': true,
    'accountant_approval_limit_cash': 0,
    'accountant_approval_limit_gold_grams': 0,
    'gold_settlement_tolerance_grams': 0.05,
    'manufacturing_wage_mode': 'inventory',
  };

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'manufacturing_wage_mode': 7};

  @override
  Future<Map<String, dynamic>> getWageTreatment() async {
    if (wageFails) throw const ApiException(statusCode: 0, code: 'network', message: 'انقطع الاتصال بالخادم');
    return {
      'mode': settings['manufacturing_wage_mode'],
      'wage_inventory_account': {'account_number': '1350', 'name': 'مخزون أجور المصنعية', 'balance': wageBalance},
    };
  }

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions, reason));
    settings.addAll(changes);
    return {'settings': Map.of(settings), 'versions': {for (final k in changes.keys) k: 99}};
  }
}

const _sizes = {'wide': Size(1400, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<(_Api, List<String>)> open(WidgetTester tester,
      {Size size = const Size(1000, 1800), bool dark = false, _Api? api}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = api ?? _Api();
    final opened = <String>[];
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(
            section: SettingsSection.accounting, api: a, financialAllowed: true,
            opener: (_, e) async => opened.add(e.id)),
      ),
    ));
    await tester.pumpAndSettle();
    return (a, opened);
  }

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text), matchRoot: true))
      .map((t) => t.data ?? '')
      .join(' ');

  Finder inDialog(Finder f) => find.descendant(of: find.byType(AlertDialog), matching: f);

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('settings-save')));

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section and the wage confirmation fit and read',
          (tester) async {
        await open(tester, size: size, dark: dark);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await tapKey(tester, 'settings-change-manufacturing_wage_mode');
        expect(find.byKey(const Key('financial-note')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('the voucher auto-post is only shown until D2, and opened where it is set', (tester) async {
    final (_, opened) = await open(tester);
    expect(textOf(tester, const Key('settings-value-voucher_auto_post')), 'مفعّل');
    expect(find.byKey(const Key('settings-change-voucher_auto_post')), findsNothing);
    expect(find.byKey(const Key('settings-field-voucher_auto_post')), findsNothing);
    expect(textOf(tester, const Key('settings-held-voucher_auto_post')), contains('القرار D2'));
    await tapKey(tester, 'settings-open-voucher_auto_post');
    expect(opened, ['voucher_auto_post']);
  });

  testWidgets('the wage treatment: each way said, the balance and its entry read, changed alone with its reason',
      (tester) async {
    final (api, _) = await open(tester);
    expect(textOf(tester, const Key('settings-value-manufacturing_wage_mode')), 'رسملة في مخزون أجور المصنعية');
    expect(find.text('الشراء يُدخل الأجور في مخزون أجور المصنعية، والبيع ينقل أجرة القطعة المباعة إلى المصروفات.'),
        findsOneWidget);
    await tapKey(tester, 'settings-change-manufacturing_wage_mode');
    expect(textOf(tester, const Key('financial-note')),
        'في 1350 مخزون أجور المصنعية رصيد مدين 1,234.50 لن يُنقل إلى المصروفات بعد التغيير. '
        'صفّره بقيد يومية: مدين مصروف أجور المصنعية، دائن 1350 مخزون أجور المصنعية.');
    await tester.tap(find.byKey(const Key('financial-choice-manufacturing_wage_mode-expense')));
    await tester.pumpAndSettle();
    expect(inDialog(find.text(
        'الشراء يحمّل الأجور على المصروفات مباشرة، والبيع لا يخصم شيئًا من مخزون أجور المصنعية.')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('financial-reason')), 'قرار المحاسب');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    final (changes, versions, reason) = api.saved.single;
    expect(changes, {'manufacturing_wage_mode': 'expense'});
    expect(versions, {'manufacturing_wage_mode': 7});
    expect(reason, 'قرار المحاسب');
    expect(textOf(tester, const Key('settings-value-manufacturing_wage_mode')), 'تحميل على المصروفات');
  });

  testWidgets('a balance that cannot be read is said, and the change still asked', (tester) async {
    final api = _Api()..wageFails = true;
    await open(tester, api: api);
    await tapKey(tester, 'settings-change-manufacturing_wage_mode');
    expect(textOf(tester, const Key('financial-note')), startsWith('تعذّر قراءة رصيد مخزون أجور المصنعية'));
    expect(find.byKey(const Key('financial-reason')), findsOneWidget);
  });

  testWidgets("the accountant's limits are not negative, and saved from the bar", (tester) async {
    final (api, _) = await open(tester);
    await tester.enterText(find.byKey(const Key('settings-field-accountant_approval_limit_cash')), '-1');
    await tester.pumpAndSettle();
    expect(find.text('لا يقل عن 0'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('settings-field-accountant_approval_limit_cash')), '5000');
    await tester.enterText(find.byKey(const Key('settings-field-accountant_approval_limit_gold_grams')), '25.5');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'accountant_approval_limit_cash': 5000.0, 'accountant_approval_limit_gold_grams': 25.5});
    expect(api.saved.single.$3, isNull, reason: 'level 2: no reason asked');
  });

  testWidgets('the gold tolerance is within 0–5 grams', (tester) async {
    final (api, _) = await open(tester);
    expect(find.text('0.05'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('settings-field-gold_settlement_tolerance_grams')), '6');
    await tester.pumpAndSettle();
    expect(find.text('بين 0 و5'), findsOneWidget);
    expect(saveButton(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('settings-field-gold_settlement_tolerance_grams')), '0.1');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'gold_settlement_tolerance_grams': 0.1});
  });
}
