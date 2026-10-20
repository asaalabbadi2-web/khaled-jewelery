import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/gold_reservations_list_screen.dart';
import 'package:frontend/screens/office_detail_screen.dart';
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
final _offices = <Map<String, dynamic>>[
    {
      'id': 5,
      'name': 'مكتب الراقي',
      'office_code': 'OFF-000002',
      'active': true,
      'balance_cash': -4000.0,
      'balance_gold_18k': 0.0,
      'balance_gold_21k': 0.0,
      'balance_gold_22k': 0.0,
      // Two grams of 24 owed to it: 2.286 of 21.
      'balance_gold_24k': -2.0,
      'open_reservations': {'count': 1, 'grams': 5.0, 'amount': 2186.15},
      'deposit': {
        'safe_box_id': 60,
        'name': 'ذهب مودع لدى مكتب الراقي',
        'weight': {'18k': 0.0, '21k': 396.6, '22k': 0.0, '24k': 0.0},
        'main_karat_total': 396.6,
      },
    },
  // A settled office: nothing between us.
  {
    'id': 6,
    'name': 'مكتب الديوان',
    'office_code': 'OFF-000004',
    'active': true,
    'balance_cash': 0.0,
    'balance_gold_18k': 0.0,
    'balance_gold_21k': 0.0,
    'balance_gold_22k': 0.0,
    'balance_gold_24k': 0.0,
    'open_reservations': {'count': 0, 'grams': 0.0, 'amount': 0.0},
    'deposit': {'main_karat_total': 0.0},
  },
];

class _FakeApi extends ApiService {
  final unsettled = <int>[];
  final stopped = <int>[];

  /// What the server says to stopping an office; none stops it.
  String? stopRefusal;

  @override
  Future<void> deleteOffice(int id) async {
    if (stopRefusal != null) throw Exception(stopRefusal);
    stopped.add(id);
  }

  /// What each load asked: active only, or all.
  final asked = <bool?>[];

  @override
  Future<List<dynamic>> getOffices({bool? activeOnly}) async {
    asked.add(activeOnly);
    return _offices;
  }

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

Future<_FakeApi> _open(WidgetTester tester, {Size size = const Size(1440, 1600)}) async {
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

  testWidgets('the card says what waits, and its reservations open the office page', (
    tester,
  ) async {
    await _open(tester);
    final button = find.byKey(const Key('office-reservations-5'));
    expect(find.descendant(of: button, matching: find.textContaining('مفتوحة')), findsOneWidget);
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(find.byType(OfficeDetailScreen), findsOneWidget);
  });

  testWidgets('all reservations, across the offices, are one tap away', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('offices-all-reservations')));
    await tester.pumpAndSettle();
    expect(find.byType(GoldReservationsListScreen), findsOneWidget);
    // Named as on the office page: an executed one is «منفَّذ», never «غير معروف».
    expect(find.textContaining('منفَّذ'), findsWidgets);
    expect(find.textContaining('غير معروف'), findsNothing);
    expect(find.textContaining('4,000.00'), findsWidgets, reason: 'amounts read with separators');
  });

  group('the offices list, release 1 (the owner, 20 Oct 2026)', () {
    testWidgets('on a phone the next step stays in sight', (tester) async {
      await _open(tester, size: const Size(390, 900));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const Key('office-new-reservation-5')).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('office-reservations-5')).hitTestable(), findsOneWidget);
    });

    testWidgets('the old balance dialog is gone: the office page says it all', (
      tester,
    ) async {
      await _open(tester);
      expect(find.text('الرصيد'), findsNothing);
    });

    testWidgets('stopping an office asks first, and says why the server refuses', (
      tester,
    ) async {
      final api = await _open(tester);
      api.stopRefusal = 'لا يُعطَّل «مكتب الراقي»: في وديعته ذهب لنا — سوِّها أولًا';
      await tester.tap(find.byKey(const Key('office-more-5')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('تعطيل').last);
      await tester.pumpAndSettle();
      expect(find.textContaining('تعطيل «مكتب الراقي»؟'), findsOneWidget);
      await tester.tap(find.byKey(const Key('office-stop-confirm')));
      await tester.pumpAndSettle();
      expect(find.textContaining('في وديعته ذهب لنا'), findsOneWidget);
      expect(api.stopped, isEmpty);
    });

    testWidgets('its gold is said in the cash\'s words, in the settings\' karat', (
      tester,
    ) async {
      await _open(tester);
      expect(
        find.descendant(
          of: find.byKey(const Key('office-gold-5')),
          matching: find.byWidgetPredicate(
            (w) =>
                w is Text &&
                (w.data ?? '').replaceAll(RegExp('[\\u2066-\\u2069]'), '') ==
                    'مستحق للمكتب 2.286 جم بالعيار 21',
          ),
        ),
        findsOneWidget,
      );
    });
  });

  group('the offices list, release 2 (the owner, 20 Oct 2026: «حجم بطاقة '
      'المكتب كبير»)', () {
    testWidgets('a card is compact: what is between us in one line', (tester) async {
      await _open(tester);
      final card = tester.getSize(find.byKey(const Key('office-card-5')));
      expect(card.height, lessThan(150), reason: 'it was about 210');
    });

    testWidgets('on a desktop the cards sit two to a row; on a phone one', (
      tester,
    ) async {
      await _open(tester);
      final a = tester.getRect(find.byKey(const Key('office-card-5')));
      final b = tester.getRect(find.byKey(const Key('office-card-6')));
      expect(a.top, b.top, reason: 'side by side');

      tester.view.physicalSize = const Size(390, 1600);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final a2 = tester.getRect(find.byKey(const Key('office-card-5')));
      final b2 = tester.getRect(find.byKey(const Key('office-card-6')));
      expect(b2.top, greaterThan(a2.bottom - 1), reason: 'one under the other');
    });

    testWidgets('nothing is said that is nothing: a settled office says so once', (
      tester,
    ) async {
      await _open(tester);
      final settled = find.byKey(const Key('office-card-6'));
      expect(find.descendant(of: settled, matching: find.text('لا شيء بيننا')), findsOneWidget);
      expect(find.descendant(of: settled, matching: find.textContaining('0.000')), findsNothing);
      expect(find.descendant(of: settled, matching: find.text('نشط')), findsNothing,
          reason: 'the list is of the active: the chip said it on every card');
    });

    testWidgets('the offices summed at the top: our gold there, what is owed, '
        'what waits', (tester) async {
      await _open(tester);
      final summary = find.byKey(const Key('offices-summary'));
      String said(String text) => text.replaceAll(RegExp('[\\u2066-\\u2069]'), '');
      final texts = [
        for (final t in tester.widgetList<Text>(find.descendant(of: summary, matching: find.byType(Text))))
          said(t.data ?? ''),
      ].join(' | ');
      expect(texts, contains('396.600 جم'));
      expect(texts, contains('4,000.00'));
      expect(texts, contains('1'));
    });

    testWidgets('active or all, said by two chips -- not an eye', (tester) async {
      final api = await _open(tester);
      expect(find.byIcon(Icons.visibility), findsNothing);
      await tester.tap(find.byKey(const Key('offices-filter-all')));
      await tester.pumpAndSettle();
      expect(api.asked.last, isNull, reason: 'all');
      await tester.tap(find.byKey(const Key('offices-filter-active')));
      await tester.pumpAndSettle();
      expect(api.asked.last, isTrue);
    });
  });
}
