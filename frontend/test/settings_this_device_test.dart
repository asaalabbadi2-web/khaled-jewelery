// «هذا الجهاز» in the center (settings spec v2, phase 7, batch 8): each
// setting read where the screens that use it read it, and saved there the
// moment it changes, said so -- no server, no save bar; a setting never set is
// what those screens take then (the voucher prints on A4, not the 80 mm the
// old tab showed); the login ticker through the settings provider, so the login
// screen sees it; «إعدادات الطابعة» opens here; nothing overflows, nothing
// vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/settings_center_screen.dart';
import 'package:frontend/settings/device_section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/invoice_settings_sheet.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  @override
  Future<Map<String, dynamic>> getSettings() async => {};

  @override
  Future<Map<String, int>> getSettingsVersions() async => {};
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

  Future<SettingsProvider> open(WidgetTester tester, Widget home,
      {Size size = const Size(1000, 1400), bool dark = false, Map<String, Object> stored = const {}}) async {
    SharedPreferences.setMockInitialValues(stored);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = SettingsProvider(fetch: () async => {});
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

  const editor = Scaffold(body: DeviceSectionEditor());

  bool switchOn(WidgetTester tester, String id) => tester.widget<Switch>(find.byKey(Key('settings-field-$id'))).value;
  bool chosen(WidgetTester tester, String id, String value) =>
      tester.widget<ChoiceChip>(find.byKey(Key('settings-field-$id-$value'))).selected;

  Future<void> tapKey(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(Key(key)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key(key)));
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the section fits and reads', (tester) async {
        await open(tester, editor, size: size, dark: dark);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('never set is what the screens take then', (tester) async {
    await open(tester, editor);
    expect(switchOn(tester, 'print_in_color'), isTrue);
    expect(chosen(tester, 'invoice_paper', 'A4'), isTrue);
    expect(chosen(tester, 'voucher_paper', 'A4'), isTrue, reason: 'the voucher prints on A4 when none is set');
    expect(chosen(tester, 'voucher_paper', '80 مم'), isFalse);
    expect(switchOn(tester, 'login_gold_ticker'), isFalse);
    expect(find.byKey(const Key('settings-save-bar')), findsNothing, reason: 'no bar: each is saved as it changes');
  });

  testWidgets('each is saved on this device as it changes, said so', (tester) async {
    await open(tester, editor);
    await tapKey(tester, 'settings-field-voucher_paper-80 مم');
    expect(find.text('حُفظ على هذا الجهاز: مقاس ورق السندات'), findsOneWidget);
    await tapKey(tester, 'settings-field-print_in_color');
    await tapKey(tester, 'settings-field-invoice_paper-Thermal');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(voucherPaperKey), '80 مم');
    expect(prefs.getBool(printInColorKey), isFalse);
    expect((await InvoiceUiSettings.load(InvoiceUiContext.saleNew)).paperSize, 'Thermal');
  });

  testWidgets('what is stored is read as stored', (tester) async {
    await open(tester, editor, stored: {
      voucherPaperKey: '58 مم',
      printInColorKey: false,
      'invoice_ui_settings_v1.global.paper_size': 'A5',
    });
    expect(chosen(tester, 'voucher_paper', '58 مم'), isTrue);
    expect(switchOn(tester, 'print_in_color'), isFalse);
    expect(chosen(tester, 'invoice_paper', 'A5'), isTrue);
  });

  testWidgets('the login ticker is the settings provider\'s, so the login screen sees it', (tester) async {
    final provider = await open(tester, editor);
    await tapKey(tester, 'settings-field-login_gold_ticker');
    expect(provider.showGoldPriceTickerOnLogin, isTrue);
    expect((await SharedPreferences.getInstance()).getBool('ui_show_gold_price_ticker_on_login_v1'), isTrue);
  });

  for (final size in [_sizes['wide']!, _sizes['phone']!]) {
    testWidgets('«إعدادات الطابعة» opens «هذا الجهاز» (${size.width})', (tester) async {
      await open(tester,
          SettingsCenterScreen(initialSection: SettingsSection.thisDevice, financialAllowed: false, api: _Api()),
          size: size);
      expect(find.byKey(const Key('settings-editor-thisDevice')), findsOneWidget);
    });
  }

  testWidgets('a search hit opens the device setting here', (tester) async {
    await open(tester, SettingsCenterScreen(financialAllowed: false, api: _Api(), opener: (_, e) async {
      fail('${e.id} opened elsewhere');
    }), size: _sizes['wide']!);
    await tester.enterText(find.byKey(const Key('settings-search')), 'أبيض وأسود');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-hit-print_in_color')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-editor-thisDevice')), findsOneWidget);
  });
}
