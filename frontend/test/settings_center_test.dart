// The settings center (settings spec v2, phase 6): a search and an index, no
// values; on a wide screen its groups beside it, on a phone a list and a page.
// A hit or a section's entry opens where it is set; nothing overflows and
// nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/screens/settings_center_screen.dart';
import 'package:frontend/settings/settings_registry.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  @override
  Future<Map<String, dynamic>> getSettings() async => {'allow_partial_invoice_payments': false, 'company_name': 'م'};

  @override
  Future<Map<String, int>> getSettingsVersions() async => {};

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => const [];
}

const _sizes = {'wide': Size(1600, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<List<String>> open(WidgetTester tester, Size size, {bool dark = false, bool financial = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final opened = <String>[];
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(ChangeNotifierProvider<SettingsProvider>(
      create: (_) => SettingsProvider(fetch: () async => {}),
      child: MaterialApp(
        theme: dark ? DarkTheme.theme : LightTheme.theme,
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: SettingsCenterScreen(opener: (_, e) async => opened.add(e.id), financialAllowed: financial, settingsAllowed: true, api: _Api()),
      ),
    ));
    await tester.pumpAndSettle();
    return opened;
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the index, a search and a section fit and read', (tester) async {
        await open(tester, size, dark: dark);
        expect(tester.takeException(), isNull);
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await tester.enterText(find.byKey(const Key('settings-search')), 'حراري');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'the results overflow');
        if (dark) expectNoTextVanishesOnDark(tester);
        await tester.enterText(find.byKey(const Key('settings-search')), '');
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('settings-index-accounting')));
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('settings-editor-accounting')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'the section overflows');
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('a wide screen keeps its groups beside it; a phone has none', (tester) async {
    await open(tester, _sizes['wide']!);
    for (final s in SettingsSection.values) {
      expect(find.byKey(Key('settings-section-${s.name}')), findsOneWidget, reason: s.name);
    }
    await open(tester, _sizes['phone']!);
    expect(find.byKey(const Key('settings-section-tax')), findsNothing);
    expect(find.byKey(const Key('settings-index-tax')), findsOneWidget);
  });

  testWidgets('a hit opens the setting itself; Enter opens the best', (tester) async {
    final opened = await open(tester, _sizes['wide']!);
    await tester.enterText(find.byKey(const Key('settings-search')), 'آجل');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-hit-allow_partial_invoice_payments')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-hit-allow_partial_invoice_payments')));
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: 'a moved setting opens here, not in the old tab');
    expect(find.byKey(const Key('settings-editor-salesInvoices')), findsOneWidget);
    expect(find.byKey(const Key('settings-row-allow_partial_invoice_payments')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('settings-search')), 'الديوان');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(opened, isEmpty, reason: 'the office terms moved too');
    expect(find.byKey(const Key('settings-group-office_terms')), findsOneWidget);
  });

  testWidgets('a section lists its settings and screens, and its device section says so', (tester) async {
    final opened = await open(tester, _sizes['wide']!);
    await tester.tap(find.byKey(const Key('settings-section-thisDevice')));
    await tester.pumpAndSettle();
    expect(find.textContaining('يُحفظ في هذا الجهاز وحده'), findsOneWidget);
    expect(find.byKey(const Key('settings-row-voucher_paper')), findsOneWidget, reason: 'edited here');
    expect(opened, isEmpty);
    await tester.tap(find.byKey(const Key('settings-section-paymentsSafes')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(const Key('settings-entry-payment_methods')), 200,
        scrollable: find.descendant(of: find.byKey(const Key('settings-editor-paymentsSafes')),
            matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(find.byKey(const Key('settings-entry-payment_methods')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-entry-payment_methods')));
    await tester.pumpAndSettle();
    expect(opened.last, 'payment_methods');
  });

  testWidgets('a phone opens a section on a page of its own', (tester) async {
    await open(tester, _sizes['phone']!);
    await tester.scrollUntilVisible(find.byKey(const Key('settings-index-backupMaintenance')), 200,
        scrollable: find.ancestor(of: find.byKey(const Key('settings-index-company')), matching: find.byType(Scrollable)).first);
    await tester.ensureVisible(find.byKey(const Key('settings-index-backupMaintenance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-index-backupMaintenance')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-section-view-backupMaintenance')), findsOneWidget);
    expect(find.byKey(const Key('settings-index-backupMaintenance')), findsNothing,
        reason: 'a page, not beside the index');
  });

  testWidgets('a phone opens an edited section on a page of its own', (tester) async {
    await open(tester, _sizes['phone']!);
    await tester.tap(find.byKey(const Key('settings-index-tax')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-editor-tax')), findsOneWidget);
    expect(find.byKey(const Key('settings-index-tax')), findsNothing, reason: 'a page, not beside the index');
  });

  testWidgets('no hit says so', (tester) async {
    await open(tester, _sizes['phone']!);
    await tester.enterText(find.byKey(const Key('settings-search')), 'زززز');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-no-hit')), findsOneWidget);
  });

  // ADR-103: a financial setting says it wants its permission to whoever lacks it.
  testWidgets('a financial setting says its permission to whoever does not hold it', (tester) async {
    await open(tester, _sizes['wide']!);
    // every financial setting is edited in the center now: alone and as a group
    await tester.tap(find.byKey(const Key('settings-section-accounting')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-needs-permission-manufacturing_wage_mode')), findsOneWidget);
    expect(find.byKey(const Key('settings-needs-permission-voucher_auto_post')), findsOneWidget,
        reason: 'D2 decided: a financial setting of the center');
    await tester.tap(find.byKey(const Key('settings-section-tax')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-needs-permission-tax_rate')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-section-goldPrices')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-needs-permission-main_karat')), findsOneWidget);
    expect(find.byKey(const Key('settings-needs-permission-office_terms')), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-section-paymentsSafes')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-needs-permission-main_cash_safe_box_id')), findsOneWidget);
    await open(tester, _sizes['wide']!, financial: true);
    for (final section in ['accounting', 'paymentsSafes', 'goldPrices', 'tax']) {
      await tester.tap(find.byKey(Key('settings-section-$section')));
      await tester.pumpAndSettle();
      expect(find.textContaining(needsFinancialPermission), findsNothing, reason: section);
    }
  });
}
