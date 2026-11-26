// What is left of the old settings screen once every section moved into the
// center (settings spec v2, phase 7 cleanup): the voucher auto-post alone,
// held there until the owner's decision D2 -- its switch and words as they
// were, saved alone, only when changed, through the settings provider (PUT);
// «حول النظام» on a page of its own; a screen that sends the user to a
// setting opens the center on it (the sales invoice's manual item, which said
// a tab that no longer holds it).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/about_screen.dart';
import 'package:frontend/screens/settings_center_screen.dart';
import 'package:frontend/screens/settings_screen_enhanced.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  bool autoPost = true;

  @override
  Future<Map<String, dynamic>> getSettings() async => {
        'voucher_auto_post': autoPost,
        'allow_partial_invoice_payments': false,
        'allow_manual_invoice_items': false,
      };

  @override
  Future<Map<String, int>> getSettingsVersions() async => {};
}

class _Provider extends SettingsProvider {
  _Provider() : super(fetch: () async => {});
  final sent = <Map<String, dynamic>>[];

  @override
  Future<void> updateSettings(Map<String, dynamic> newSettings) async => sent.add(newSettings);
}

const _sizes = {'wide': Size(1400, 1000), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<_Provider> open(WidgetTester tester, Widget home, {Size size = const Size(1000, 1200), bool dark = false}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = _Provider();
    await tester.pumpWidget(ChangeNotifierProvider<SettingsProvider>.value(
      value: provider,
      child: MaterialApp(
        theme: dark ? DarkTheme.theme : LightTheme.theme,
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: home,
      ),
    ));
    await tester.pumpAndSettle();
    return provider;
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the held page and «حول النظام» fit and read', (tester) async {
        await open(tester, SettingsScreenEnhanced(api: _Api()), size: size, dark: dark);
        expect(find.byKey(const Key('held-voucher-auto-post')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await open(tester, const AboutScreen(), size: size, dark: dark);
        expect(find.text('نظام مجوهرات خالد'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) expectNoTextVanishesOnDark(tester);
      });
    }
  }

  testWidgets('the voucher auto-post is saved alone, only when changed, as before', (tester) async {
    final provider = await open(tester, SettingsScreenEnhanced(api: _Api()));
    final toggle = find.byKey(const Key('held-voucher-auto-post'));
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue, reason: 'read from the server');
    expect(find.text('ترحيل السندات تلقائياً عند الحفظ'), findsOneWidget, reason: 'its words, unchanged (D2)');
    expect(tester.widget<FilledButton>(find.byKey(const Key('held-save'))).onPressed, isNull, reason: 'unchanged');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('held-save')));
    await tester.pumpAndSettle();
    expect(provider.sent, [
      {'voucher_auto_post': false}
    ]);
    expect(tester.widget<FilledButton>(find.byKey(const Key('held-save'))).onPressed, isNull, reason: 'saved');
  });

  testWidgets('the held page sends the user to the center for the rest', (tester) async {
    await open(tester, SettingsScreenEnhanced(api: _Api()), size: _sizes['wide']!);
    await tester.tap(find.text('افتح المركز'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsCenterScreen), findsOneWidget);
  });

  for (final size in _sizes.values) {
    testWidgets('a screen that sends the user to a setting opens the center on it (${size.width})', (tester) async {
      await open(tester,
          SettingsCenterScreen(initialSetting: 'allow_manual_invoice_items', financialAllowed: false, api: _Api()),
          size: size);
      expect(find.byKey(const Key('settings-editor-salesInvoices')), findsOneWidget);
      final box = tester.widget<Container>(find.ancestor(
        of: find.byKey(const Key('settings-row-allow_manual_invoice_items')),
        matching: find.byType(Container),
      ).first);
      expect(((box.decoration as BoxDecoration).border as Border).top.width, 2, reason: 'framed');
    });
  }

  // The old screen's tabs are gone: nothing opens it but the held setting's
  // link, and no screen's words send the user to a tab.
  test('nothing opens the old screen but the held setting, and no words name its tabs', () {
    final opens = <String>[];
    final names = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final src = f.readAsStringSync();
      if (src.contains('SettingsScreenEnhanced(') && !f.path.endsWith('settings_screen_enhanced.dart')) opens.add(f.path);
      if (RegExp(r'الإعدادات\s*>\s*(عام|الشركة والفواتير|المدفوعات|محاسبة|الطباعة|النظام)').hasMatch(src)) {
        names.add(f.path);
      }
    }
    expect(opens, ['lib/settings/settings_opener.dart']);
    expect(names, isEmpty);
    final sale = File('lib/screens/sales_invoice_screen_v2.dart').readAsStringSync();
    expect(sale.contains("SettingsCenterScreen(initialSetting: 'allow_manual_invoice_items')"), isTrue);
  });
}
