import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/offices_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// «مكاتب التسكير» after the bank model (ADR-052; the owner 19 Oct 2026: the
/// journey from an office to its reservation to its execution).
///
/// The card showed the supplier's weight alone -- Al-Raqi «عليه 0.000 جم» with
/// 396.6 g of ours in its deposit; its reservations were behind a tap on the
/// card; an executed one was struck through as if cancelled, with no way back.
class _FakeApi extends ApiService {
  final unsettled = <int>[];

  @override
  Future<List<dynamic>> getOffices({bool? activeOnly}) async => [
    {
      'id': 5,
      'name': 'مكتب الراقي',
      'office_code': 'OFF-000002',
      'active': true,
      'balance_cash': -4000.0,
      'balance_gold_18k': 0.0,
      'balance_gold_21k': 0.0,
      'balance_gold_22k': 0.0,
      'balance_gold_24k': 0.0,
      'deposit': {
        'safe_box_id': 60,
        'name': 'ذهب مودع لدى مكتب الراقي',
        'weight': {'18k': 0.0, '21k': 396.6, '22k': 0.0, '24k': 0.0},
        'main_karat_total': 396.6,
      },
    },
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
  }) async => {
    'data': [
      {
        'id': 36,
        'reservation_code': 'RES-0036',
        'status': 'completed',
        'purchase_invoice_id': 3402,
        'karat': 21,
        'weight_grams': 10.0,
        'weight_main_karat': 10.0,
        'total_amount': 4000.0,
        'paid_amount': 0.0,
        'reservation_date': '2026-10-19T09:11:55',
      },
    ],
  };

  @override
  Future<Map<String, dynamic>> unsettleOfficeReservation(
    int reservationId, {
    String? reason,
  }) async {
    unsettled.add(reservationId);
    return {'id': reservationId, 'status': 'pending'};
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
  tester.view.physicalSize = const Size(1440, 1600);
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
          child: OfficesScreen(api: api),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('the card shows the gold of ours deposited there, and what is owed', (
    tester,
  ) async {
    await _open(tester);
    final deposit = find.byKey(const Key('office-deposit-5'));
    expect(
      find.descendant(of: deposit, matching: find.textContaining('396.600')),
      findsOneWidget,
    );
    final cash = find.byKey(const Key('office-cash-5'));
    expect(
      find.descendant(of: cash, matching: find.textContaining('مستحق للمكتب')),
      findsOneWidget,
    );
  });

  testWidgets('the next steps are on the card, not behind a tap', (
    tester,
  ) async {
    await _open(tester);
    expect(find.byKey(const Key('office-new-reservation-5')), findsOneWidget);
    expect(find.byKey(const Key('office-reservations-5')), findsOneWidget);
  });

  testWidgets('an executed reservation is not struck through, and is undone by name', (
    tester,
  ) async {
    final api = await _open(tester);
    await tester.tap(find.byKey(const Key('office-reservations-5')));
    await tester.pumpAndSettle();

    final struck = tester
        .widgetList<Text>(find.descendant(of: find.byType(AlertDialog), matching: find.byType(Text)))
        .where((t) => t.style?.decoration == TextDecoration.lineThrough);
    expect(struck, isEmpty, reason: 'executed is not cancelled');
    expect(find.textContaining('منفَّذ'), findsOneWidget);

    await tester.tap(find.byKey(const Key('reservation-unexecute-36')));
    await tester.pumpAndSettle();
    expect(find.textContaining('يخرج'), findsOneWidget, reason: 'it says what it undoes');
    await tester.tap(find.widgetWithText(ElevatedButton, 'تأكيد').last);
    await tester.pumpAndSettle();
    expect(api.unsettled, [36]);
  });
}
