// «الذهب والأسعار» in the center (settings spec v2, phase 7, batch 3):
// the main karat changed alone through its confirmation, and never guessed
// when it is not set; the office terms one policy -- one card, one
// confirmation, one reason, one save of what changed: a part changed alone
// would stamp a price with terms no one set (routes/system.py); the buy ratio
// and the price update saved from the bar, within their bounds, as the
// server bounds them; nothing overflows, nothing vanishes in the dark.
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
  Object? fail;

  final settings = <String, dynamic>{
    'main_karat': 21,
    'buy_price_ratio': 0.99,
    'office_main_fees_usd': 1.35,
    'office_custom_fees_usd': 43,
    'office_discount_21': 0.75,
    'office_discount_18': 1,
    'gold_price_auto_update_enabled': true,
    'gold_price_auto_update_interval_seconds': 15,
  };

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async =>
      {'main_karat': 4, 'office_main_fees_usd': 8, 'office_discount_21': 9, 'buy_price_ratio': 2};

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions, reason));
    final f = fail;
    if (f != null) {
      fail = null;
      throw f;
    }
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

  Future<_Api> open(WidgetTester tester,
      {Size size = const Size(1000, 1600), bool dark = false, _Api? api, String? highlight}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = api ?? _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(
            section: SettingsSection.goldPrices, api: a, financialAllowed: true, highlight: highlight,
            opener: (_, _) async {}),
      ),
    ));
    await tester.pumpAndSettle();
    return a;
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

  FilledButton confirm(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('financial-confirm')));

  Future<void> reason(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('financial-reason')), text);
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section and the office terms fit and read', (tester) async {
        await open(tester, size: size, dark: dark);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await tapKey(tester, 'settings-change-office_terms');
        expect(find.byKey(const Key('financial-field-office_discount_18')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('the main karat is changed alone, said with what it does to the books', (tester) async {
    final api = await open(tester);
    expect(textOf(tester, const Key('settings-value-main_karat')), 'عيار 21');
    await tapKey(tester, 'settings-change-main_karat');
    expect(find.descendant(of: find.byType(AlertDialog),
        matching: find.text('بعد أول قيد بوزن لا يُعاد: تغييره يخلط وحدتين في الدفاتر (القرار D9).')), findsOneWidget);
    expect(confirm(tester).onPressed, isNull, reason: 'unchanged');
    await tester.tap(find.byKey(const Key('financial-choice-main_karat-24')));
    await reason(tester, 'بدء السنة الجديدة');
    expect(textOf(tester, const Key('financial-after')), contains('عيار 24'));
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    final (changes, versions, why) = api.saved.single;
    expect(changes, {'main_karat': 24});
    expect(versions, {'main_karat': 4});
    expect(why, 'بدء السنة الجديدة');
    expect(textOf(tester, const Key('settings-value-main_karat')), 'عيار 24');
  });

  // D9 (ADR-105): after the books' first weight the server refuses another
  // main karat -- the center says it is locked, and offers no change.
  testWidgets('a main karat the books are weighed in is said locked, and not offered', (tester) async {
    final api = _Api()..settings['main_karat_locked'] = true;
    await open(tester, api: api);
    expect(textOf(tester, const Key('settings-value-main_karat')), 'عيار 21');
    expect(find.byKey(const Key('settings-change-main_karat')), findsNothing);
    expect(find.byKey(const Key('settings-locked-main_karat')), findsOneWidget);
    expect(find.byKey(const Key('settings-change-office_terms')), findsOneWidget, reason: 'the rest of the section is not');
  });

  testWidgets('a main karat not set is said so, never guessed', (tester) async {
    final api = _Api()..settings['main_karat'] = null;
    await open(tester, api: api);
    expect(textOf(tester, const Key('settings-value-main_karat')), 'غير مضبوط');
    await tapKey(tester, 'settings-change-main_karat');
    for (final k in [18, 21, 22, 24]) {
      expect(tester.widget<ChoiceChip>(find.byKey(Key('financial-choice-main_karat-$k'))).selected, isFalse,
          reason: 'عيار $k is not chosen for the owner');
    }
  });

  testWidgets('the office terms are one card, changed together: one reason, one save of what changed', (tester) async {
    final api = await open(tester);
    expect(find.byKey(const Key('settings-group-office_terms')), findsOneWidget);
    for (final k in ['office_main_fees_usd', 'office_custom_fees_usd', 'office_discount_21', 'office_discount_18']) {
      expect(find.byKey(Key('settings-change-$k')), findsNothing, reason: '$k is not changed alone');
    }
    expect(textOf(tester, const Key('settings-value-office_main_fees_usd')), '1.35 دولار للأونصة');
    expect(textOf(tester, const Key('settings-value-office_custom_fees_usd')), '43 دولار للأونصة');
    await tapKey(tester, 'settings-change-office_terms');
    await tester.enterText(find.byKey(const Key('financial-field-office_main_fees_usd')), '1.5');
    await tester.enterText(find.byKey(const Key('financial-field-office_discount_21')), '0.8');
    await tester.pumpAndSettle();
    expect(textOf(tester, const Key('financial-line-office_main_fees_usd')), contains('1.35 دولار للأونصة ← 1.5'));
    expect(textOf(tester, const Key('financial-line-office_custom_fees_usd')), isNot(contains('←')));
    expect(confirm(tester).onPressed, isNull, reason: 'no reason yet');
    await reason(tester, 'المكتب رفع الرسوم');
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    final (changes, versions, why) = api.saved.single;
    expect(changes, {'office_main_fees_usd': 1.5, 'office_discount_21': 0.8});
    expect(versions, {'office_main_fees_usd': 8, 'office_discount_21': 9});
    expect(why, 'المكتب رفع الرسوم');
    expect(textOf(tester, const Key('settings-value-office_discount_21')), '0.8 ريال للغرام');
  });

  testWidgets('an office term out of the server\'s bounds is said, and not saved', (tester) async {
    await open(tester);
    await tapKey(tester, 'settings-change-office_terms');
    await tester.enterText(find.byKey(const Key('financial-field-office_custom_fees_usd')), '600');
    await reason(tester, 'سبب');
    expect(find.text('بين 0 و500'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('financial-field-office_custom_fees_usd')), '');
    await tester.pumpAndSettle();
    expect(find.text('اكتب رقمًا'), findsOneWidget);
    expect(confirm(tester).onPressed, isNull);
  });

  testWidgets('a term another user moved closes the dialog on the terms now', (tester) async {
    final api = await open(tester);
    api.fail = const ApiException(statusCode: 409, code: 'settings_conflict', message: 'تعارض', details: {
      'conflicts': [
        {'key': 'office_discount_21', 'current': 0.9, 'yours': 0.8, 'current_version': 15, 'changed_by': 'saleh'},
      ],
    });
    await tapKey(tester, 'settings-change-office_terms');
    await tester.enterText(find.byKey(const Key('financial-field-office_discount_21')), '0.8');
    await reason(tester, 'سبب');
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('financial-reason')), findsNothing);
    expect(textOf(tester, const Key('settings-value-office_discount_21')), '0.9 ريال للغرام');
    expect(find.textContaining('saleh'), findsOneWidget);
  });

  testWidgets('the buy ratio is written as a percent, kept as a fraction, within 50–100', (tester) async {
    final api = await open(tester);
    expect(find.text('99'), findsOneWidget, reason: '0.99 written 99');
    await tester.enterText(find.byKey(const Key('settings-field-buy_price_ratio')), '40');
    await tester.pumpAndSettle();
    expect(find.text('بين 50 و100'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const Key('settings-save'))).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('settings-field-buy_price_ratio')), '98.5');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'buy_price_ratio': 0.985});
    expect(api.saved.single.$3, isNull, reason: 'a level-2 setting wants no reason');
  });

  testWidgets('the price update: its interval set only while it runs, 10 seconds at the least', (tester) async {
    final api = await open(tester);
    await tapKey(tester, 'settings-field-gold_price_auto_update_interval_seconds-60');
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'gold_price_auto_update_interval_seconds': 60}, reason: 'whole seconds');
    await tester.enterText(find.byKey(const Key('settings-field-gold_price_auto_update_interval_seconds')), '5');
    await tester.pumpAndSettle();
    expect(find.text('بين 10 و604,800'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-discard')));
    await tester.pumpAndSettle();
    await tapKey(tester, 'settings-field-gold_price_auto_update_enabled');
    final field = tester.widget<TextField>(find.byKey(const Key('settings-field-gold_price_auto_update_interval_seconds')));
    expect(field.enabled, isFalse, reason: 'no update, no interval to set');
  });

  testWidgets('a search for an office term frames the terms\' card', (tester) async {
    await open(tester, highlight: 'office_discount_18');
    final box = tester.widget<Container>(find.ancestor(
      of: find.byKey(const Key('settings-group-office_terms')),
      matching: find.byType(Container),
    ).first);
    expect(((box.decoration as BoxDecoration).border as Border).top.width, 2);
  });
}
