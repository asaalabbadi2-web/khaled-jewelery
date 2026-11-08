// ADR-087 R3.4: «محطة ترميز القطع». The list is the server's lines left to
// code; a line opened, each piece typed and sent with its attempt's key --
// the server's number shown to write on its tag, the counter moved, the
// wage «بانتظار الفاتورة» until the invoice. Refused, the server's words are
// said and the next attempt is a new key; a lost answer keeps the key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
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
  ApiException? refuseNext;
  bool loseNext = false;
  int _n = 0;

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
}
