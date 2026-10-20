import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_voucher_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_voucher_api.dart';

/// The voucher screen as the employee meets it, for the tests that drive it.

Future<void> loadCairo() async {
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
}

/// The screen over a page, as the app opens it, so leaving it lands somewhere.
Future<FakeVoucherApi> openVoucher(
  WidgetTester tester, {
  FakeVoucherApi? api,
  String voucherType = 'payment',
  int? supplierId = 5,
  String? partyType,
  Map<String, dynamic>? existing,
  Size size = const Size(1440, 2400),
}) async {
  api ??= FakeVoucherApi();
  SharedPreferences.setMockInitialValues({
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider.value(value: settings),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AddVoucherScreen(
                        voucherType: voucherType,
                        initialSupplierId: supplierId,
                        initialPartyType: partyType,
                        existingVoucher: existing,
                        apiService: api,
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return api;
}

/// Text that reads [shown], the direction isolates around its numbers set aside.
Finder said(String shown) => find.byWidgetPredicate((w) {
  if (w is! Text) return false;
  final text = w.data ?? w.textSpan?.toPlainText() ?? '';
  return text.replaceAll(RegExp('[\u2066-\u2069]'), '').contains(shown);
});

Finder cashAmount() =>
    find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first;

Future<void> pickSafe(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const Key('voucher-line-account-0')));
  await tester.pumpAndSettle();
  await tester.tap(find.textContaining(name).last);
  await tester.pumpAndSettle();
}

Future<void> toGold(WidgetTester tester) async {
  await tester.tap(find.text('ذهب').first);
  await tester.pumpAndSettle();
}

Future<void> grams(WidgetTester tester, String typed) async {
  await tester.enterText(
    find.widgetWithText(TextFormField, 'الوزن (جرام) *').first,
    typed,
  );
  await tester.pumpAndSettle();
}

Future<void> save(WidgetTester tester) async {
  await tester.tap(find.text('حفظ السند').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('voucher-review-save')));
  await tester.pumpAndSettle();
}
