import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/office_detail_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// One office's page (ADR-052, journey release 2): it replaced a dialog behind a
/// tap on the card. Its balances, its reservations by state, and each one's
/// next step -- execute or cancel an open one, undo an executed one -- each
/// saying what it does before it does it.
const _office = {
  'id': 5,
  'name': 'مكتب الراقي',
  'office_code': 'OFF-000002',
  'supplier_id': 20,
  'active': true,
  'balance_cash': -4000.0,
  'balance_gold_18k': 0.0,
  'balance_gold_21k': 0.0,
  'balance_gold_22k': 0.0,
  'balance_gold_24k': 0.0,
  'deposit': {'main_karat_total': 396.6},
  'open_reservations': {'count': 1, 'grams': 5.0, 'amount': 2186.15},
};

class _FakeApi extends ApiService {
  final settled = <int>[];
  final cancelled = <int>[];
  final unsettled = <int>[];

  @override
  Future<List<dynamic>> getOffices({bool? activeOnly}) async => [_office];

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
  }) async => {
    'data': [
      {
        'id': 38,
        'reservation_code': 'RES-0038',
        'status': 'approved',
        'purchase_invoice_id': null,
        'karat': 21,
        'weight_grams': 5.0,
        'price_per_gram': 437.23,
        'total_amount': 2186.15,
        'paid_amount': 0.0,
        'reservation_date': '2026-10-20T07:52:29',
      },
      {
        'id': 36,
        'reservation_code': 'RES-0036',
        'status': 'completed',
        'purchase_invoice_id': 3402,
        'karat': 21,
        'weight_grams': 10.0,
        'price_per_gram': 400.0,
        'total_amount': 4000.0,
        'paid_amount': 0.0,
        'reservation_date': '2026-10-19T09:11:55',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> settleOfficeReservation(
    int reservationId, {
    double? executionPricePerGram,
    DateTime? settlementDate,
    String? createdBy,
  }) async {
    settled.add(reservationId);
    return {};
  }

  @override
  Future<Map<String, dynamic>> cancelOfficeReservation(
    int reservationId, {
    String? cancelledBy,
    String? reason,
  }) async {
    cancelled.add(reservationId);
    return {};
  }

  @override
  Future<Map<String, dynamic>> unsettleOfficeReservation(
    int reservationId, {
    String? reason,
  }) async {
    unsettled.add(reservationId);
    return {};
  }
}

Future<_FakeApi> _open(WidgetTester tester, {Size size = const Size(1440, 1400)}) async {
  final cairo = FontLoader('Cairo');
  for (final w in ['Regular', 'SemiBold', 'Bold']) {
    cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
  }
  await cairo.load();
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = size;
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
        home: OfficeDetailScreen(api: api, office: Map.of(_office)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

Finder _in(String key, Finder f) =>
    find.descendant(of: find.byKey(Key(key)), matching: f, matchRoot: true);

void main() {
  testWidgets('it says what is ours there and what is owed, with the next steps in sight', (
    tester,
  ) async {
    await _open(tester);
    expect(_in('office-page-deposit', find.textContaining('396.600')), findsOneWidget);
    expect(_in('office-page-cash', find.textContaining('مستحق للمكتب')), findsOneWidget);
    expect(find.byKey(const Key('office-page-trade')), findsNothing, reason: 'no trade gold: not shown');
    for (final k in ['office-page-new-reservation', 'office-page-pay', 'office-page-statement']) {
      expect(find.byKey(Key(k)), findsOneWidget, reason: k);
    }
  });

  testWidgets('the open reservations first, each with execute and cancel', (tester) async {
    await _open(tester);
    expect(find.textContaining('مفتوحة (', findRichText: true), findsWidgets);
    expect(find.byKey(const Key('office-page-reservation-38')), findsOneWidget);
    expect(find.byKey(const Key('office-page-reservation-36')), findsNothing, reason: 'executed: its own tab');
    expect(find.byKey(const Key('office-page-execute-38')), findsOneWidget);
    expect(find.byKey(const Key('office-page-cancel-38')), findsOneWidget);
    expect(_in('office-page-summary', find.textContaining('2,186.15')), findsOneWidget);
  });

  testWidgets('executing says the gold enters the deposit and the rest is owed', (tester) async {
    final api = await _open(tester);
    await tester.tap(find.byKey(const Key('office-page-execute-38')));
    await tester.pumpAndSettle();
    expect(find.textContaining('وديعة «مكتب الراقي»'), findsOneWidget);
    expect(find.textContaining('دينًا للمكتب'), findsOneWidget);
    await tester.tap(find.byKey(const Key('office-confirm-action')));
    await tester.pumpAndSettle();
    expect(api.settled, [38]);
  });

  testWidgets('an executed reservation is undone by name, never struck through', (tester) async {
    final api = await _open(tester);
    await tester.tap(find.textContaining('منفَّذة ('));
    await tester.pumpAndSettle();
    final struck = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.style?.decoration == TextDecoration.lineThrough);
    expect(struck, isEmpty);
    await tester.tap(find.byKey(const Key('office-page-undo-36')));
    await tester.pumpAndSettle();
    expect(find.textContaining('من الوديعة'), findsOneWidget);
    await tester.tap(find.byKey(const Key('office-confirm-action')));
    await tester.pumpAndSettle();
    expect(api.unsettled, [36]);
  });

  testWidgets('it lays out on a phone', (tester) async {
    await _open(tester, size: const Size(390, 1600));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('office-page-execute-38')), findsOneWidget);
  });
}
