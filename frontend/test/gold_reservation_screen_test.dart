import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/gold_reservation_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The reservation's price follows its karat (the owner, 19 Oct 2026): it
/// opened at karat 24 with the 24k price, and choosing 21 kept 503.94 -- 20 g
/// read 10,078.80 where 21k is ~440. The prices are the server's, per karat
/// (prices_per_gram), not computed here from the ounce and a written rate.
class _FakeApi extends ApiService {
  final sent = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getGoldPrice() async => {
    'main_karat': 21,
    'price_usd_per_oz': 4185.26,
    'prices_per_gram': {
      '18': {'buy': 374.66, 'sell': 378.45},
      '21': {'buy': 437.11, 'sell': 441.52},
      '22': {'buy': 457.92, 'sell': 462.55},
      '24': {'buy': 499.55, 'sell': 504.6},
    },
  };

  @override
  Future<List<dynamic>> getOffices({bool? activeOnly}) async => [
    {'id': 5, 'name': 'مكتب الراقي', 'active': true},
  ];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => const [];

  @override
  Future<List<dynamic>> getActivePaymentMethods({String? invoiceType}) async =>
      const [];

  @override
  Future<Map<String, dynamic>> createOfficeReservation(
    Map<String, dynamic> reservationData,
  ) async {
    sent.add(reservationData);
    return {'id': 1, 'reservation_code': 'RES-1'};
  }
}

Future<_FakeApi> _open(WidgetTester tester) async {
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = const Size(1440, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final api = _FakeApi();
  await tester.pumpWidget(
    ChangeNotifierProvider.value(
      value: settings,
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: GoldReservationScreen(api: api),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

String _field(WidgetTester tester, String label) => tester
    .widget<TextField>(
      find.descendant(
        of: find.widgetWithText(TextFormField, label),
        matching: find.byType(TextField),
      ),
    )
    .controller!
    .text;

void main() {
  testWidgets('it opens at the main karat with its price', (tester) async {
    await _open(tester);
    expect(find.text('عيار 21'), findsWidgets);
    expect(_field(tester, 'السعر للجرام (ر.س)'), '441.52');
  });

  testWidgets('choosing a karat brings its price, and the total follows', (
    tester,
  ) async {
    await _open(tester);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'الوزن (جرام)'),
      '20',
    );
    await tester.pumpAndSettle();
    expect(_field(tester, 'المبلغ الإجمالي (ر.س)'), '8830.40');

    await tester.tap(find.text('عيار 21').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('عيار 24').last);
    await tester.pumpAndSettle();
    expect(_field(tester, 'السعر للجرام (ر.س)'), '504.60');
    expect(_field(tester, 'المبلغ الإجمالي (ر.س)'), '10092.00');
  });
}
