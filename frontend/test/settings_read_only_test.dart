// B15 (the owner, 26 Nov 2026): whoever does not hold «إعدادات النظام»
// (system.settings) reads the company's settings, said so, with no control
// to change them -- not «تعذّر تحميل الإعدادات», as the versions, theirs to ask
// only to save, were refused. A safe the reader may not list is said by its
// number, not «no longer there»; «هذا الجهاز» stays everyone's; nothing
// overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/settings_center_screen.dart';
import 'package:frontend/settings/section_editor.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

const _refused = ApiException(statusCode: 403, code: 'permission_denied', message: 'لا تملك الصلاحية');

class _Api extends ApiService {
  int versionsAsked = 0;

  @override
  Future<Map<String, dynamic>> getSettings() async => {
        'company_name': 'مجوهرات خالد', 'company_phone': '0500000000', 'show_company_logo': true,
        'currency_symbol': 'ر.س', 'decimal_places': 2, 'date_format': 'DD/MM/YYYY',
        'main_karat': 21, 'buy_price_ratio': 0.99, 'office_main_fees_usd': 1.35, 'office_custom_fees_usd': 43,
        'office_discount_21': 0.75, 'office_discount_18': 1,
        'main_cash_safe_box_id': 38, 'employee_cash_safes_enabled': false,
      };

  @override
  Future<Map<String, int>> getSettingsVersions() async {
    versionsAsked++;
    throw _refused;
  }

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async =>
      throw _refused;
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

  Future<void> pump(WidgetTester tester, Widget home, {Size size = const Size(1000, 1600), bool dark = false}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<SettingsProvider>(
      create: (_) => SettingsProvider(fetch: () async => {}),
      child: MaterialApp(
        theme: dark ? DarkTheme.theme : LightTheme.theme,
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: home,
      ),
    ));
    await tester.pumpAndSettle();
  }

  Widget section(SettingsSection s, _Api api) =>
      Scaffold(body: SectionEditor(section: s, api: api, settingsAllowed: false, opener: (_, _) async {}));

  String textOf(WidgetTester tester, String key) => tester
      .widgetList<Text>(find.descendant(of: find.byKey(Key(key)), matching: find.byType(Text), matchRoot: true))
      .map((t) => t.data ?? '')
      .join(' ');

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: a section read only fits and reads', (tester) async {
        await pump(tester, section(SettingsSection.company, _Api()), size: size, dark: dark);
        expect(find.byKey(const Key('settings-read-only')), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('read only: each value said, no control, no bar, the versions not asked', (tester) async {
    final api = _Api();
    await pump(tester, section(SettingsSection.company, api));
    expect(api.versionsAsked, 0, reason: 'asked only of whoever may save');
    expect(find.byType(TextField), findsNothing);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(textOf(tester, 'settings-value-company_phone'), '0500000000');
    expect(textOf(tester, 'settings-value-show_company_logo'), 'مفعّل');
    expect(textOf(tester, 'settings-value-currency_symbol'), 'ر.س', reason: 'the currency said by its name');
    expect(find.byKey(const Key('settings-save-bar')), findsNothing);
  });

  testWidgets('read only: a financial setting and a policy group offer no change, and no permission note',
      (tester) async {
    await pump(tester, section(SettingsSection.goldPrices, _Api()));
    expect(find.byType(OutlinedButton), findsNothing, reason: 'no «تغيير…»');
    expect(textOf(tester, 'settings-value-main_karat'), 'عيار 21');
    expect(textOf(tester, 'settings-value-office_main_fees_usd'), '1.35 دولار للأونصة');
    expect(find.textContaining(needsFinancialPermission), findsNothing, reason: 'the section says what it needs');
  });

  testWidgets('read only: a safe the reader may not list is said by its number', (tester) async {
    await pump(tester, section(SettingsSection.paymentsSafes, _Api()));
    expect(textOf(tester, 'settings-value-main_cash_safe_box_id'), 'خزينة رقم 38');
    expect(find.textContaining('غير موجودة'), findsNothing);
  });

  testWidgets('in the center: a company section reads, «هذا الجهاز» is still set', (tester) async {
    await pump(tester, SettingsCenterScreen(financialAllowed: false, settingsAllowed: false, api: _Api()),
        size: const Size(1400, 1000));
    await tester.tap(find.byKey(const Key('settings-section-company')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-read-only')), findsOneWidget);
    expect(find.textContaining('تعذّر تحميل'), findsNothing);
    await tester.tap(find.byKey(const Key('settings-section-thisDevice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-field-print_in_color')), findsOneWidget, reason: "the device's own");
  });
}
