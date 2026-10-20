import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/gold_reservation_screen.dart';
import 'package:frontend/screens/office_detail_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/payload_witness.dart';

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
    {
      'id': 5,
      'name': 'مكتب الراقي',
      'active': true,
      'supplier_id': 20,
      'contact_person': 'أبو خالد',
      'phone': '0500000001',
    },
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
  Future<List<dynamic>> getActivePaymentMethods({String? invoiceType}) async => [
    {'id': 9, 'name': 'نقداً', 'default_safe_box_id': 1},
  ];

  @override
  Future<Map<String, dynamic>> getOfficeReservations({
    int? officeId,
    String? status,
    String? paymentStatus,
    String? dateFrom,
    String? dateTo,
    int? limit,
    int? page,
    int? perPage,
    String? orderBy,
    String? orderDirection,
  }) async => {'data': const []};

  @override
  Future<Map<String, dynamic>> createOfficeReservation(
    Map<String, dynamic> reservationData,
  ) async {
    sent.add(reservationData);
    return {'id': 1, 'reservation_code': 'RES-1'};
  }
}

Future<_FakeApi> _open(WidgetTester tester, {int? officeId}) async {
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
          child: GoldReservationScreen(api: api, initialOfficeId: officeId),
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
  payloadTests();
  layoutTests();
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
    // The total is read, not typed (journey release 3): in the form and its bar.
    expect(find.textContaining('8,830.40'), findsWidgets);

    await tester.ensureVisible(find.text('عيار 21').first);
    await tester.tap(find.text('عيار 21').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('عيار 24').last);
    await tester.pumpAndSettle();
    expect(_field(tester, 'السعر للجرام (ر.س)'), '504.60');
    expect(find.textContaining('10,092.00'), findsWidgets);
  });
}

/// What the form sends when it saves -- kept whole in test/payloads (ADR-049
/// UI-2): the redesign of the form (journey release 3) changes how it reads,
/// never what reaches the server. Written from the form before the redesign.
Future<void> _save(WidgetTester tester) async {
  final save = find.text('حفظ الحجز');
  await tester.ensureVisible(save);
  await tester.tap(save);
  await tester.pumpAndSettle();
  await tester.tap(find.text('تأكيد').last);
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String label, String text) async {
  final field = find.widgetWithText(TextFormField, label);
  await tester.ensureVisible(field);
  await tester.enterText(field, text);
  await tester.pumpAndSettle();
}

/// The deposit's section, where the form keeps it closed.
Future<void> _openDeposit(WidgetTester tester) async {
  final section = find.byKey(const Key('reservation-deposit'));
  if (section.evaluate().isEmpty) return;
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}

void payloadTests() {
  testWidgets('it sends what it sent: no deposit', (tester) async {
    final api = await _open(tester, officeId: 5);
    await _type(tester, 'الوزن (جرام)', '20');
    await _save(tester);
    expect(api.sent, hasLength(1));
    expectPayload('office_reservation_plain', api.sent.single);
  });

  testWidgets('it sends what it sent: a deposit paid by a way to pay', (tester) async {
    final api = await _open(tester, officeId: 5);
    await _type(tester, 'الوزن (جرام)', '20');
    await _openDeposit(tester);
    await _type(tester, 'المبلغ المدفوع', '1000');
    final method = find.widgetWithText(DropdownButtonFormField<int>, 'وسيلة الدفع');
    await tester.ensureVisible(method);
    await tester.tap(method);
    await tester.pumpAndSettle();
    await tester.tap(find.text('نقداً').last);
    await tester.pumpAndSettle();
    await _save(tester);
    expect(api.sent, hasLength(1));
    expectPayload('office_reservation_deposit', api.sent.single);
  });
}

/// The redesign (journey release 3): two columns on a wide screen, one on a
/// phone; the deposit and the details folded until wanted; the market price
/// beside the price, restored in a tap; saving from the menu goes on to the
/// office's page, where the reservation waits to be executed.
void layoutTests() {
  testWidgets('two columns on a desktop, one on a phone', (tester) async {
    await _open(tester);
    final reservation = tester.getCenter(find.byKey(const Key('reservation-weight')));
    final deposit = tester.getCenter(find.byKey(const Key('reservation-deposit')));
    expect((reservation.dx - deposit.dx).abs(), greaterThan(300), reason: 'side by side');

    tester.view.physicalSize = const Size(390, 2400);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final r2 = tester.getCenter(find.byKey(const Key('reservation-weight')));
    final d2 = tester.getCenter(find.byKey(const Key('reservation-deposit')));
    expect(d2.dy, greaterThan(r2.dy), reason: 'one under the other');
  });

  testWidgets('the deposit and the details are folded until wanted', (tester) async {
    await _open(tester);
    expect(find.widgetWithText(TextFormField, 'المبلغ المدفوع').hitTestable(), findsNothing);
    expect(find.widgetWithText(TextFormField, 'ملاحظات').hitTestable(), findsNothing);
    expect(find.textContaining('لا عربون'), findsOneWidget);
  });

  testWidgets('a price typed over the market price comes back in a tap', (tester) async {
    await _open(tester);
    expect(find.textContaining('سعر السوق لعيار 21'), findsOneWidget);
    expect(find.byKey(const Key('reservation-price-reset')), findsNothing);
    await tester.enterText(find.byKey(const Key('reservation-price')), '430');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reservation-price-reset')));
    await tester.pumpAndSettle();
    expect(_field(tester, 'السعر للجرام (ر.س)'), '441.52');
  });

  testWidgets('saved from the menu, it goes on to the office page', (tester) async {
    await _open(tester);
    final office = find.widgetWithText(DropdownButtonFormField<int>, 'اختر المكتب');
    await tester.tap(office);
    await tester.pumpAndSettle();
    await tester.tap(find.text('مكتب الراقي').last);
    await tester.pumpAndSettle();
    await _type(tester, 'الوزن (جرام)', '5');
    await _save(tester);
    expect(find.byType(OfficeDetailScreen), findsOneWidget);
  });
}
