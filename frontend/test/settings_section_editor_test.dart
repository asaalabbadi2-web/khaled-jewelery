// A section edited in the center (settings spec v2, phase 7; ADR-102): only
// what changed is sent, at the version seen; a key another user moved since
// is settled key by key, the user's values kept; a failed save keeps them
// and offers to retry; a percent is kept as a fraction, as the old screen
// kept it; nothing overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/settings/section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  final saved = <(Map<String, dynamic>, Map<String, int>)>[];
  Object? fail;

  final settings = <String, dynamic>{
    'company_name': 'مجوهرات خالد', 'company_address': 'الطائف', 'company_phone': '0500000000',
    'company_tax_number': '311326867900003', 'company_cr_number': '4032050276', 'show_company_logo': true,
    'invoice_prefix': 'INV', 'currency_symbol': 'ر.س', 'decimal_places': 2, 'date_format': 'DD/MM/YYYY',
    'allow_discount': true, 'default_discount_rate': 0.05, 'allow_manual_invoice_items': false,
    'allow_partial_invoice_payments': false, 'require_auth_for_invoice_create': true,
  };

  @override
  Future<Map<String, dynamic>> getSettings() async => Map.of(settings);

  @override
  Future<Map<String, int>> getSettingsVersions() async => {'company_phone': 7, 'invoice_prefix': 3};

  @override
  Future<Map<String, dynamic>> patchSettings({
    required Map<String, dynamic> changes,
    required Map<String, int> versions,
    String? reason,
  }) async {
    saved.add((changes, versions));
    final f = fail;
    if (f != null) {
      fail = null;
      throw f;
    }
    return {'settings': {...settings, ...changes}, 'versions': {for (final k in changes.keys) k: 99}};
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

  Future<_Api> open(WidgetTester tester, SettingsSection section,
      {Size size = const Size(1000, 1400), bool dark = false, String? highlight}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: Scaffold(
        body: SectionEditor(section: section, api: api, highlight: highlight, opener: (_, _) async {}),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: a section and its bar fit and read', (tester) async {
        await open(tester, SettingsSection.company, size: size, dark: dark);
        await tester.enterText(find.byKey(const Key('settings-field-company_phone')), '0511111111');
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings-save-bar')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('only what changed is sent, at the version seen', (tester) async {
    final api = await open(tester, SettingsSection.company);
    expect(find.byKey(const Key('settings-save-bar')), findsNothing, reason: 'nothing changed, no bar');
    await tester.enterText(find.byKey(const Key('settings-field-company_phone')), '0511111111');
    await tester.enterText(find.byKey(const Key('settings-field-invoice_prefix')), 'SELL');
    await tester.pumpAndSettle();
    expect(find.text('تعديلان لم يُحفظا في هذا القسم'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    final (changes, versions) = api.saved.single;
    expect(changes, {'company_phone': '0511111111', 'invoice_prefix': 'SELL'});
    expect(versions, {'company_phone': 7, 'invoice_prefix': 3});
    expect(find.byKey(const Key('settings-save-bar')), findsNothing, reason: 'saved');
  });

  testWidgets('«تجاهل التعديلات» puts back what was', (tester) async {
    await open(tester, SettingsSection.company);
    await tester.enterText(find.byKey(const Key('settings-field-company_phone')), '0511111111');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-discard')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
    expect(find.text('0500000000'), findsOneWidget);
  });

  testWidgets('a key another user moved is settled key by key, the values kept', (tester) async {
    final api = await open(tester, SettingsSection.company);
    api.fail = const ApiException(statusCode: 409, code: 'settings_conflict', message: 'تعارض', details: {
      'conflicts': [
        {'key': 'company_phone', 'current': '0599999999', 'yours': '0511111111', 'current_version': 12,
          'changed_by': 'saleh'},
      ],
    });
    await tester.enterText(find.byKey(const Key('settings-field-company_phone')), '0511111111');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-conflict-company_phone')), findsOneWidget);
    expect(find.textContaining('saleh'), findsOneWidget);
    expect(find.text('0511111111'), findsOneWidget, reason: 'the user\'s value stays in its field');
    await tester.tap(find.byKey(const Key('settings-keep-mine-company_phone')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.last.$2, {'company_phone': 12}, reason: 'saved over the other knowingly, at its version');
  });

  testWidgets("taking the other's value leaves nothing to save", (tester) async {
    final api = await open(tester, SettingsSection.company);
    api.fail = const ApiException(statusCode: 409, code: 'settings_conflict', message: 'تعارض', details: {
      'conflicts': [
        {'key': 'company_phone', 'current': '0599999999', 'yours': '0511111111', 'current_version': 12},
      ],
    });
    await tester.enterText(find.byKey(const Key('settings-field-company_phone')), '0511111111');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-take-theirs-company_phone')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
    expect(find.text('0599999999'), findsOneWidget);
  });

  testWidgets('a failed save keeps the values and offers to retry', (tester) async {
    final api = await open(tester, SettingsSection.company);
    api.fail = const ApiException(statusCode: 0, code: 'network', message: 'انقطع الاتصال بالخادم');
    await tester.enterText(find.byKey(const Key('settings-field-company_phone')), '0511111111');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-save-error')), findsOneWidget);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    expect(find.text('0511111111'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.length, 2);
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
  });

  testWidgets('a discount is kept as a fraction, and is set only while discounts are allowed', (tester) async {
    final api = await open(tester, SettingsSection.salesInvoices);
    expect(find.text('5.0%'), findsOneWidget, reason: '0.05 read as 5 %');
    await tester.tap(find.byKey(const Key('settings-field-allow_discount')));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byKey(const Key('settings-field-default_discount_rate')));
    expect(slider.onChanged, isNull, reason: 'no discount, no default to set');
    await tester.tap(find.byKey(const Key('settings-field-allow_discount')));
    await tester.pumpAndSettle();
    tester.widget<Slider>(find.byKey(const Key('settings-field-default_discount_rate'))).onChanged!(10);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-save')));
    await tester.pumpAndSettle();
    expect(api.saved.single.$1, {'default_discount_rate': 0.1});
  });

  testWidgets('a search opens a setting on its row, framed', (tester) async {
    await open(tester, SettingsSection.salesInvoices, highlight: 'allow_partial_invoice_payments');
    final box = tester.widget<Container>(find.ancestor(
      of: find.byKey(const Key('settings-row-allow_partial_invoice_payments')),
      matching: find.byType(Container),
    ).first);
    final border = (box.decoration as BoxDecoration).border as Border;
    expect(border.top.width, 2);
  });
}
