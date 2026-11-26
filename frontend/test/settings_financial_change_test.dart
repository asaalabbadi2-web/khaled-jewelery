// A financial (level-3) setting in the center (settings spec v2 §7.2;
// ADR-102, ADR-103): changed alone, never with the section's bar, through
// its confirmation -- the value now and after, what it changes, how far it is
// undone, and a reason it is not saved without; only that key is sent, with
// its version and its reason. Whoever lacks the permission is told, not
// handed a dead button; a refusal keeps the dialog and what was typed; a key
// another user moved closes it on the value now. «الضريبة» is the first
// section of them: its rate by tenths, its exempt karats never none, its
// worked examples kept from the old tab.
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
    'currency_symbol': 'ر.س',
    'tax_enabled': true,
    'sales_vat_enabled': true,
    'tax_rate': 0.15,
    'vat_exempt_karats': '["24"]',
  };

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'tax_rate': 5, 'sales_vat_enabled': 2};

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
      {Size size = const Size(1000, 1400), bool dark = false, bool allowed = true, _Api? api}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final a = api ?? _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(section: SettingsSection.tax, api: a, financialAllowed: allowed, opener: (_, _) async {}),
      ),
    ));
    await tester.pumpAndSettle();
    return a;
  }

  Future<void> change(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key('settings-change-$key')));
    await tester.tap(find.byKey(Key('settings-change-$key')));
    await tester.pumpAndSettle();
  }

  String textOf(WidgetTester tester, Key key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(key), matching: find.byType(Text), matchRoot: true))
      .map((t) => t.data ?? '')
      .join(' ');

  FilledButton confirm(WidgetTester tester) => tester.widget<FilledButton>(find.byKey(const Key('financial-confirm')));

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section and its confirmation fit and read', (tester) async {
        await open(tester, size: size, dark: dark);
        expect(tester.takeException(), isNull);
        await change(tester, 'tax_rate');
        expect(find.byKey(const Key('financial-reason')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('each financial setting says its value, and is changed through «تغيير…», never the bar', (tester) async {
    await open(tester);
    expect(textOf(tester, const Key('settings-value-tax_rate')), '15.0%');
    expect(textOf(tester, const Key('settings-value-vat_exempt_karats')), 'عيار 24');
    expect(textOf(tester, const Key('settings-value-sales_vat_enabled')), 'مفعّل');
    expect(find.byType(Switch), findsNothing, reason: 'no switch flips a financial setting in place');
    expect(find.byType(Slider), findsNothing);
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
    expect(find.byKey(const Key('settings-tax-examples')), findsOneWidget, reason: 'the old tab\'s examples kept');
  });

  testWidgets('no reason, no save; the before, the after, what it changes and how it is undone are said',
      (tester) async {
    final api = await open(tester);
    await change(tester, 'sales_vat_enabled');
    expect(textOf(tester, const Key('financial-before')), contains('مفعّل'));
    expect(textOf(tester, const Key('financial-after')), contains('معطّل'), reason: 'a switch is changed by flipping');
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('تُكتب فترة من اليوم في سياسة الضريبة.')), findsOneWidget);
    expect(find.descendant(of: find.byType(AlertDialog), matching: find.text('فترة جديدة؛ ما بيع بين الفترتين يبقى كما بيع.')), findsOneWidget);
    expect(confirm(tester).onPressed, isNull, reason: 'no reason yet');
    await tester.enterText(find.byKey(const Key('financial-reason')), '   ');
    await tester.pump();
    expect(confirm(tester).onPressed, isNull, reason: 'spaces are no reason');
    await tester.enterText(find.byKey(const Key('financial-reason')), 'إعفاء مؤقت بقرار المحاسب');
    await tester.pump();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    final (changes, versions, reason) = api.saved.single;
    expect(changes, {'sales_vat_enabled': false}, reason: 'that key alone');
    expect(versions, {'sales_vat_enabled': 2});
    expect(reason, 'إعفاء مؤقت بقرار المحاسب');
    expect(find.byKey(const Key('financial-reason')), findsNothing, reason: 'closed');
    expect(textOf(tester, const Key('settings-value-sales_vat_enabled')), 'معطّل');
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
  });

  testWidgets('the rate moves by tenths and is kept as a fraction', (tester) async {
    final api = await open(tester);
    await change(tester, 'tax_rate');
    final slider = tester.widget<Slider>(find.byKey(const Key('financial-value')));
    expect(slider.divisions, 300, reason: '0–30 by 0.1, as the old tab');
    expect(confirm(tester).onPressed, isNull, reason: 'unchanged is nothing to confirm');
    slider.onChanged!(15.5);
    await tester.enterText(find.byKey(const Key('financial-reason')), 'تعديل النظام');
    await tester.pumpAndSettle();
    expect(textOf(tester, const Key('financial-after')), contains('15.5%'));
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'tax_rate': 0.155});
    expect(api.saved.single.$2, {'tax_rate': 5});
    expect(textOf(tester, const Key('settings-value-tax_rate')), '15.5%');
  });

  testWidgets('the exempt karats are never none: none is 24', (tester) async {
    final api = await open(tester);
    await change(tester, 'vat_exempt_karats');
    await tester.tap(find.byKey(const Key('financial-karat-24')));
    await tester.pumpAndSettle();
    expect(confirm(tester).onPressed, isNull, reason: 'none fell back to 24: nothing changed');
    await tester.tap(find.byKey(const Key('financial-karat-22')));
    await tester.enterText(find.byKey(const Key('financial-reason')), 'سبب');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {
      'vat_exempt_karats': [22, 24]
    });
  });

  testWidgets('tax off: its rate and karats are not changed, and no examples are worked', (tester) async {
    final api = _Api()..settings['tax_enabled'] = false;
    await open(tester, api: api);
    for (final key in ['tax_rate', 'vat_exempt_karats']) {
      expect(tester.widget<OutlinedButton>(find.byKey(Key('settings-change-$key'))).onPressed, isNull, reason: key);
    }
    expect(tester.widget<OutlinedButton>(find.byKey(const Key('settings-change-tax_enabled'))).onPressed, isNotNull);
    expect(find.byKey(const Key('settings-tax-examples')), findsNothing);
  });

  testWidgets('without the permission each says what it needs, and is not opened', (tester) async {
    await open(tester, allowed: false);
    for (final key in ['tax_enabled', 'sales_vat_enabled', 'tax_rate', 'vat_exempt_karats']) {
      expect(tester.widget<OutlinedButton>(find.byKey(Key('settings-change-$key'))).onPressed, isNull, reason: key);
      expect(textOf(tester, Key('settings-needs-permission-$key')), needsFinancialPermission, reason: key);
    }
  });

  testWidgets('a refusal is said in the dialog, the value and the reason kept', (tester) async {
    final api = await open(tester);
    api.fail = const ApiException(
        statusCode: 403, code: 'financial_settings_permission', message: 'يحتاج صلاحية الإعدادات المالية');
    await change(tester, 'tax_enabled');
    await tester.enterText(find.byKey(const Key('financial-reason')), 'سبب واضح');
    await tester.pump();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(textOf(tester, const Key('financial-error')), 'يحتاج صلاحية الإعدادات المالية');
    expect(find.text('سبب واضح'), findsOneWidget);
    expect(textOf(tester, const Key('financial-after')), contains('معطّل'));
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(api.saved.length, 2, reason: 'tried again from the dialog');
    expect(textOf(tester, const Key('settings-value-tax_enabled')), 'معطّل');
  });

  testWidgets('a rate another user moved closes the dialog on the value now', (tester) async {
    final api = await open(tester);
    api.fail = const ApiException(statusCode: 409, code: 'settings_conflict', message: 'تعارض', details: {
      'conflicts': [
        {'key': 'tax_rate', 'current': 0.05, 'yours': 0.155, 'current_version': 12, 'changed_by': 'saleh'},
      ],
    });
    await change(tester, 'tax_rate');
    tester.widget<Slider>(find.byKey(const Key('financial-value'))).onChanged!(15.5);
    await tester.enterText(find.byKey(const Key('financial-reason')), 'سبب');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('financial-reason')), findsNothing, reason: 'its «الآن» was no longer now');
    expect(textOf(tester, const Key('settings-value-tax_rate')), '5.0%');
    expect(find.textContaining('saleh'), findsOneWidget);
    await change(tester, 'tax_rate');
    tester.widget<Slider>(find.byKey(const Key('financial-value'))).onChanged!(15);
    await tester.enterText(find.byKey(const Key('financial-reason')), 'سبب');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('financial-confirm')));
    await tester.pumpAndSettle();
    expect(api.saved.last.$2, {'tax_rate': 12}, reason: 'at the version it now knows');
  });
}
