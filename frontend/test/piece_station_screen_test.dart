// ADR-087 R3.4: «محطة ترميز القطع». The list is the server's lines left to
// code; a line opened, each piece typed and sent with its attempt's key --
// the server's number shown to write on its tag, the counter moved, the
// wage «بانتظار الفاتورة» until the invoice. Refused, the server's words are
// said and the next attempt is a new key; a lost answer keeps the key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/screens/piece_station_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _line({int pieces = 0, double coded = 0}) => {
  'line_id': 7, 'invoice_id': 900, 'invoice_number': 'PUR-2027-00001', 'stage': 'received',
  'supplier_name': 'مفيد الحبيشي', 'category_id': 28, 'category_name': 'بنجرة ذهب 21',
  'karat': 21, 'weight': 30.0, 'pieces': pieces, 'pieces_weight': coded,
  'rest': double.parse((30.0 - coded).toStringAsFixed(3)),
};

class _Api extends ApiService {
  final sent = <Map<String, dynamic>>[];
  final opened = <Map<String, dynamic>>[];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [
    SafeBoxModel.fromJson({'id': 3, 'account_id': 30, 'name': 'المعرض', 'safe_type': 'gold', 'stock_location': 'showroom'}),
    SafeBoxModel.fromJson({'id': 4, 'account_id': 40, 'name': 'وديعة المكتب', 'safe_type': 'gold', 'stock_location': 'deposit'}),
  ];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
    {'id': 28, 'name': 'بنجرة ذهب 21', 'karat': '21', 'is_active': true, 'tracking': 'piece'},
    {'id': 30, 'name': 'خواتم 21', 'karat': '21', 'is_active': true},
  ];

  @override
  Future<Map<String, dynamic>> stockCodingRoom(int safeBoxId, int categoryId) async =>
      {'free': 120.0, 'reserved': 0.0, 'room': 120.0, 'karat': 21};

  @override
  Future<Map<String, dynamic>> openStockCoding(Map<String, dynamic> body) async {
    opened.add(body);
    return {
      'line': {'kind': 'stock', 'line_id': null, 'coding_id': 5, 'invoice_number': 'ترميز مخزون #5',
               'safe_name': 'المعرض', 'category_name': 'بنجرة ذهب 21', 'karat': 21, 'weight': 50.0,
               'pieces': 0, 'pieces_weight': 0.0, 'rest': 50.0},
      'pieces': [],
    };
  }

  ApiException? refuseNext;
  bool loseNext = false;
  int _n = 0;

  final tagged = <int>[];

  @override
  Future<Map<String, dynamic>> mountPieceTag(int pieceId) async {
    tagged.add(pieceId);
    return {
      'tag': {'value': '4B4A00000000000000000121'},
      'piece': {'id': pieceId, 'item_code': 'KJ-000121', 'weight': 14.37, 'stones_weight': 0,
                'wage': null, 'wage_known': false, 'tag': '4B4A00000000000000000121'},
    };
  }

  @override
  Future<List<Map<String, dynamic>>> piecesPending() async => [_line()];

  @override
  Future<Map<String, dynamic>> pieceLine(int lineId) async => {'line': _line(), 'pieces': []};

  @override
  Future<Map<String, dynamic>> registerPiece(Map<String, dynamic> body) async {
    sent.add(body);
    if (refuseNext != null) {
      final e = refuseNext!;
      refuseNext = null;
      throw e;
    }
    if (loseNext) {
      loseNext = false;
      throw Exception('connection lost');
    }
    _n++;
    final w = (body['weight'] as num).toDouble();
    return {
      'piece': {'id': 100 + _n, 'item_code': 'KJ-00012$_n', 'weight': w, 'stones_weight': 0,
                'wage': null, 'wage_known': false},
      'line': _line(pieces: _n, coded: w),
    };
  }
}

Future<void> _open(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('station-line-7')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a piece typed is sent with its key; its number shown, the counter moved', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.textContaining('الباقي 30.00 جم'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['line_id'], 7);
    expect(api.sent.single['weight'], 14.37);
    expect(api.sent.single['request_key'], isNotEmpty);
    expect(find.descendant(of: find.byKey(const Key('station-last')), matching: find.text('KJ-000121')),
        findsOneWidget);
    expect(find.textContaining('الباقي 15.63 جم'), findsOneWidget);
    expect(find.text('بانتظار الفاتورة'), findsOneWidget);
  });

  testWidgets('refused, the words said and the next attempt a new key', (tester) async {
    final api = _Api()
      ..refuseNext = const ApiException(statusCode: 400, code: 'piece_heavier_than_rest',
          message: 'القطعة (31.00 جم) أثقل من باقي السطر (30.00 جم)');
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '31');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(find.textContaining('أثقل من باقي السطر'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], isNot(api.sent[0]['request_key']));
  });

  testWidgets('a lost answer keeps the key: sent again, the same piece', (tester) async {
    final api = _Api()..loseNext = true;
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], api.sent[0]['request_key']);
  });

  testWidgets('no weight, nothing sent', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, isEmpty);
  });

  testWidgets('from the stock a location holds: a batch opened, its wage by hand, coded here', (tester) async {
    final api = _Api();
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-from-stock')));
    await tester.pumpAndSettle();
    expect(find.text('وديعة المكتب'), findsNothing, reason: 'an office deposit is not coded');
    await tester.tap(find.byKey(const Key('coding-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المعرض').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-category')));
    await tester.pumpAndSettle();
    expect(find.text('خواتم 21'), findsNothing, reason: 'only categories tracked by the piece');
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('المتاح للترميز: 120.00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('coding-weight')), '50');
    await tester.tap(find.text('أجرة الدفعة كلها'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('coding-wage')), '750');
    await tester.tap(find.byKey(const Key('coding-open')));
    await tester.pumpAndSettle();
    expect(api.opened.single, {'safe_box_id': 3, 'category_id': 28, 'weight': 50.0, 'wage_per_gram': 15.0});
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['coding_id'], 5);
    expect(api.sent.single.containsKey('line_id'), isFalse);
  });

  testWidgets('a piece\'s tag is recorded once written; then it is replaced, not doubled', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-tag-101')));
    await tester.pumpAndSettle();
    expect(api.tagged, [101]);
    expect(find.byKey(const Key('station-tag-101')), findsNothing);
    expect(find.byKey(const Key('station-retag-101')), findsOneWidget);
  });
}
