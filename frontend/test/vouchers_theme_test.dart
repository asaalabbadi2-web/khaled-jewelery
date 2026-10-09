import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_voucher_screen.dart';
import 'package:frontend/screens/vouchers_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_voucher_api.dart';

/// ثيم-٠ (VOUCHER-UX-1، المرحلة ٤): شاشة إضافة السند وقائمة السندات تأخذان
/// ألوانهما من الثيم، فتُرسمان في الوضعين. الحدّ على الألوان المكتوبة فيهما في
/// `theme_raw_color_ratchet_test.dart` (صفر، واثنان للقائمة: لونا ورق PDF).
class _ListApi extends FakeVoucherApi {
  @override
  Future<Map<String, dynamic>> getVouchers({
    int page = 1,
    int perPage = 20,
    String? type,
    String? status,
    String? dateFrom,
    String? dateTo,
    String? search,
    String? searchType,
    String? creator,
    String? party,
    String? sortBy,
    String? sortOrder,
    String? referenceType,
    int? referenceId,
  }) async => {
    'vouchers': [
      for (final (n, t, st, cash, gold) in [
        ('RV-2026-00010', 'receipt', 'approved', 1500.0, 0.0),
        ('PV-2026-00011', 'payment', 'pending', 0.0, 12.5),
        ('AV-2026-00012', 'adjustment', 'cancelled', 300.0, 0.0),
      ])
        {
          'id': n.hashCode & 0xffff,
          'voucher_number': n,
          'voucher_type': t,
          'status': st,
          'date': '2026-10-08T10:00:00',
          'party_name': 'مورد الذهب',
          'party_type': 'supplier',
          'amount_cash': cash,
          'amount_gold': gold,
          'description': 'دفعة',
          'created_by': 'موظف',
        },
    ],
    'total': 3,
    'pages': 1,
    'current_page': 1,
    'per_page': 20,
  };
}

/// A user who may see and add vouchers.
class _Clerk extends AuthProvider {
  @override
  bool hasPermission(String key) => key.startsWith('vouchers.');
}

const dir = String.fromEnvironment('SHOT_DIR');

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<void> pump(WidgetTester tester, ThemeData theme, Widget child) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(create: (_) => _Clerk()),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          theme: theme,
          home: Directionality(textDirection: TextDirection.rtl, child: child),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> shot(WidgetTester tester, String name) async {
    if (dir.isEmpty) return;
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('$dir/$name.png'),
    );
  }

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('adding a voucher, and its review, draw in the $name theme', (
      tester,
    ) async {
      await pump(
        tester,
        theme,
        AddVoucherScreen(
          voucherType: 'payment',
          initialSupplierId: 5,
          apiService: FakeVoucherApi(
            similar: const [
              {
                'id': 77,
                'voucher_number': 'PV-2026-00077',
                'date': '2026-10-02T00:00:00',
                'amount_cash': 500.0,
                'amount_gold': 0.0,
              },
            ],
          ),
        ),
      );
      await tester.tap(find.text('اختر حساب/خزينة').first);
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('الصندوق').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first,
        '500',
      );
      await tester.pump();
      expect(find.text('جاهز للحفظ'), findsOneWidget);
      await shot(tester, 'voucher_add_$name');

      await tester.tap(find.text('حفظ السند').last);
      await tester.pumpAndSettle();
      expect(find.text('مراجعة سند صرف'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await shot(tester, 'voucher_review_$name');
    });

    testWidgets('the vouchers list draws in the $name theme', (tester) async {
      await pump(tester, theme, VouchersListScreen(apiService: _ListApi()));

      expect(find.textContaining('RV-2026-00010'), findsWidgets);
      expect(tester.takeException(), isNull);
      await shot(tester, 'voucher_list_$name');
    });
  }
}
