// بيع واحد في التسكير (ADR-048 المرحلة 3أ): البطاقة تعرض ما يقوله الخادم عن
// ريالات البيع -- ما رُدّ وما أُغلق وبماذا وما ينتظر -- ولا تحسب شيئًا، ولا
// تظهر لما ليس بيعًا قائمًا. ورقم «تنفيذات» في الحجوزات لا يظهر صفرًا.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/gold_reservations_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/sale_closing_card.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _view() => {
      'invoice_id': 3280, 'invoice_number': 1618, 'status': 'partially_closed',
      'cash': 6000.0, 'grams': 10.0, 'expected_at_sale': 2.0,
      'returned_cash': 1000.0, 'returned_grams': 1.667, 'returned_after_closing_cash': 0.0,
      'closed_cash': 2600.0, 'cash_open': 2400.0, 'grams_open': 4.0,
      'realized': -0.333, 'unrealized': 0.8,
      'closings': [
        {'date': '2026-10-03T10:00:00', 'kind': 'expense', 'invoice_id': null, 'invoice_number': null,
         'cash': 600.0, 'grams_in': 0.0, 'grams_out': 1.0, 'result': -1.0},
        {'date': '2026-10-04T10:00:00', 'kind': 'customer', 'invoice_id': 90, 'invoice_number': 812,
         'cash': 2000.0, 'grams_in': 4.0, 'grams_out': 3.333, 'result': 0.667},
      ],
    };

class _Api extends ApiService {
  _Api(this.answer) : super(baseUrl: 'http://test');
  final Future<Map<String, dynamic>?> Function() answer;
  int calls = 0;

  @override
  Future<Map<String, dynamic>?> getSaleWeightClosing(int invoiceId) {
    calls++;
    return answer();
  }
}

Future<void> _pump(WidgetTester tester, ApiService api) async {
  await tester.pumpWidget(MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(body: SingleChildScrollView(child: SaleClosingCard(api: api, invoiceId: 3280))),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a sale\'s riyals: returned, closed by what, and waiting -- as the server says', (tester) async {
    await _pump(tester, _Api(() async => _view()));
    expect(find.text('مُسكَّر جزئيًّا'), findsOneWidget);
    expect(find.textContaining('رُدّ بمرتجع \u20661,000.00\u2069 ر.س'), findsOneWidget);
    final closed = tester.widget<Text>(find.byKey(const ValueKey('sale-closing-closed')));
    expect(closed.data, 'أُغلق \u20662,600.00\u2069 ر.س، نتيجته \u2066−0.333\u2069 غ');
    expect(find.byKey(const ValueKey('sale-closing-open')), findsOneWidget);
    expect(find.text('مصروف · \u20662026-10-03\u2069'), findsOneWidget);
    expect(find.text('شراء كسر من عميل #812 · \u20662026-10-04\u2069'), findsOneWidget);
    expect(find.text('\u2066+0.667\u2069 غ'), findsOneWidget);
  });

  testWidgets('a fully closed sale shows nothing waiting', (tester) async {
    await _pump(tester, _Api(() async => {..._view(), 'status': 'closed', 'cash_open': 0.0, 'grams_open': 0.0}));
    expect(find.text('مُسكَّر'), findsOneWidget);
    expect(find.byKey(const ValueKey('sale-closing-open')), findsNothing);
  });

  testWidgets('a return after the riyals turned into gold is shown apart', (tester) async {
    await _pump(tester, _Api(() async => {..._view(), 'status': 'closed', 'returned_cash': 0.0,
                                         'returned_after_closing_cash': 3000.0, 'cash_open': 0.0}));
    expect(find.byKey(const ValueKey('sale-closing-returned-after')), findsOneWidget);
    expect(find.textContaining('رُدّ بمرتجع'), findsNothing);
  });

  testWidgets('a sale nothing closed yet says only what waits', (tester) async {
    await _pump(tester, _Api(() async => {..._view(), 'status': 'open', 'closed_cash': 0.0, 'realized': 0.0,
                                         'closings': <Map<String, dynamic>>[]}));
    expect(find.text('ينتظر التسكير'), findsOneWidget);
    expect(find.byKey(const ValueKey('sale-closing-closed')), findsNothing);
    expect(find.byKey(const ValueKey('sale-closing-open')), findsOneWidget);
  });

  testWidgets('not a standing sale, or not for this reader: nothing at all', (tester) async {
    await _pump(tester, _Api(() async => null));
    expect(find.byKey(const ValueKey('sale-closing')), findsNothing);
    expect(find.text('التسكير'), findsNothing);
  });

  testWidgets('a failure says so and can be retried -- no dead end', (tester) async {
    var fail = true;
    final api = _Api(() async {
      if (fail) throw Exception('network');
      return _view();
    });
    await _pump(tester, api);
    expect(find.byKey(const ValueKey('sale-closing-error')), findsOneWidget);
    fail = false;
    await tester.tap(find.text('إعادة المحاولة'));
    await tester.pumpAndSettle();
    expect(api.calls, 2);
    expect(find.byKey(const ValueKey('sale-closing')), findsOneWidget);
  });

  group('reservations', () {
    Future<void> pumpList(WidgetTester tester, List<Map<String, dynamic>> rows) async {
      final cairo = FontLoader('Cairo');
      for (final f in ['Regular', 'SemiBold', 'Bold']) {
        cairo.addFont(rootBundle.load('assets/fonts/Cairo-$f.ttf'));
      }
      await cairo.load();
      SharedPreferences.setMockInitialValues({'app_settings': jsonEncode({'main_karat': 21})});
      tester.view.physicalSize = const Size(1440, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SettingsProvider();
      await settings.loadSettings(fetchRemote: false);
      await tester.pumpWidget(ChangeNotifierProvider.value(
        value: settings,
        child: MaterialApp(theme: LightTheme.theme, home: GoldReservationsListScreen(api: _Reservations(rows))),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('a settlement since phase 3a shows no «executions 0»; an old one keeps its count', (tester) async {
      await pumpList(tester, [_reservation(1, executions: 0), _reservation(2, executions: 3)]);
      expect(find.text('تنفيذات 0'), findsNothing);
      expect(find.text('تنفيذات 3'), findsOneWidget);
      expect(find.byKey(const ValueKey('reservation-executions')), findsOneWidget);
    });
  });
}

Map<String, dynamic> _reservation(int id, {required int executions}) => {
      'id': id, 'reservation_code': 'RES-$id', 'office_id': 1, 'office_name': 'مكتب',
      'status': 'completed', 'payment_status': 'paid', 'karat': 24, 'weight_main_karat': 10.0,
      'weight_grams': 10.0, 'total_amount': 5000.0, 'paid_amount': 5000.0, 'remaining_amount': 0.0,
      'price_per_gram': 500.0, 'reservation_date': '2026-10-10T10:00:00', 'executions_created': executions,
    };

class _Reservations extends ApiService {
  _Reservations(this.rows) : super(baseUrl: 'http://test');
  final List<Map<String, dynamic>> rows;

  @override
  Future<List<dynamic>> getOffices({bool? activeOnly}) async => [
        {'id': 1, 'name': 'مكتب'},
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
  }) async =>
      {'data': rows, 'pagination': {'page': 1, 'per_page': 20, 'total': rows.length, 'pages': 1}};
}
