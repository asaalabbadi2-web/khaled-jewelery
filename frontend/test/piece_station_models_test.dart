// The station by the model and the size (ADR-093 M2; the owner, 17 Nov 2026):
// the model chosen once for the line, each piece its size and weight; the
// sizes offered are the model's when it names them, else its category's
// system's; the size kept for the next piece; the invoice's wage against the
// model's said as a warning -- the piece keeps the invoice's; the models not
// read, the piece is coded without one.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/piece_station_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _line({int pieces = 0, double coded = 0}) => {
      'kind': 'receipt', 'line_id': 7, 'invoice_id': 900, 'invoice_number': 'REC-2027-00031', 'stage': 'received',
      'supplier_name': 'المورد ب', 'category_id': 28, 'category_name': 'بنجرة ذهب 21', 'size_system_id': 1,
      'karat': 21, 'weight': 120.0, 'pieces': pieces, 'pieces_weight': coded,
      'rest': double.parse((120.0 - coded).toStringAsFixed(3)),
    };

const _sun = {
  'id': 5,
  'name': 'بنجرة الشمس',
  'supplier_code': 'SUP-A-118',
  'expected_wage_per_gram': 39.0,
  'thumbnail': null,
  'sizes': [
    {'id': 11, 'label': '17', 'position': 1},
    {'id': 12, 'label': '18', 'position': 2},
  ],
};

class _Api extends ApiService {
  _Api({this.modelsFail = false});

  final bool modelsFail;
  final sent = <Map<String, dynamic>>[];
  int _n = 0;

  @override
  Future<List<Map<String, dynamic>>> piecesPending() async => [_line()];

  @override
  Future<Map<String, dynamic>> pieceLine(int lineId) async => {'line': _line(), 'pieces': []};

  @override
  Future<List<Map<String, dynamic>>> getPieceModels({int? categoryId, String? q, bool includeInactive = false}) async {
    if (modelsFail) throw Exception('offline');
    return [_sun];
  }

  @override
  Future<List<Map<String, dynamic>>> getSizeSystems() async => [
        {
          'id': 1,
          'name': 'مقاسات البناجر',
          'sizes': [
            {'id': 11, 'label': '17', 'position': 1, 'pieces': 0},
            {'id': 12, 'label': '18', 'position': 2, 'pieces': 0},
            {'id': 13, 'label': '19', 'position': 3, 'pieces': 0},
          ],
          'categories': [],
        },
      ];

  @override
  Future<Map<String, dynamic>> pieceWageCheck({int? lineId, int? codingId, required int modelId}) async =>
      {'state': 'model_wage_differs', 'invoice_per_gram': 41.0, 'expected_per_gram': 39.0};

  @override
  Future<Map<String, dynamic>> registerPiece(Map<String, dynamic> body) async {
    sent.add(body);
    _n++;
    final w = (body['weight'] as num).toDouble();
    return {
      'piece': {
        'id': 100 + _n, 'item_code': 'KJ-00024$_n', 'weight': w, 'stones_weight': 0, 'wage': null,
        'wage_known': false,
        'size': body['size_id'] == null ? null : {'id': body['size_id'], 'label': body['size_id'] == 12 ? '18' : '19'},
        'model': body['model_id'] == null ? null : {'id': 5, 'name': 'بنجرة الشمس'},
      },
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

Future<void> _piece(WidgetTester tester, String weight) async {
  await tester.enterText(find.byKey(const Key('piece-weight')), weight);
  await tester.tap(find.byKey(const Key('piece-register')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no model: the category\'s sizes; the size kept for the next piece', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.text('بلا موديل'), findsOneWidget);
    for (final id in [11, 12, 13]) {
      expect(find.byKey(Key('station-size-$id')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('station-size-13')));
    await tester.pumpAndSettle();
    await _piece(tester, '22.10');
    await _piece(tester, '21.85');
    expect([for (final b in api.sent) b['size_id']], [13, 13], reason: 'kept for the next piece');
    expect(api.sent.first.containsKey('model_id'), isFalse);
  });

  testWidgets('a model: its sizes only, the wage warning, and the piece says its size and model', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('station-model-change')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-model-5')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('station-size-13')), findsNothing, reason: 'the model comes in 17 and 18');
    expect(find.byKey(const Key('station-wage-differs')), findsOneWidget);
    expect(find.textContaining('القطع تأخذ أجرة الفاتورة'), findsOneWidget);
    await tester.tap(find.byKey(const Key('station-size-12')));
    await tester.pumpAndSettle();
    await _piece(tester, '20.90');
    expect((api.sent.single['model_id'], api.sent.single['size_id']), (5, 12));
    expect(find.textContaining('مقاس 18 · بنجرة الشمس'), findsOneWidget);
  });

  testWidgets('the models not read: said, and the piece is coded without one', (tester) async {
    final api = _Api(modelsFail: true);
    await _open(tester, api);
    expect(find.text('تعذّر تحميل الموديلات: القطعة تُسجَّل بلا موديل'), findsOneWidget);
    await _piece(tester, '20.00');
    expect(api.sent.single.containsKey('model_id'), isFalse);
  });
}
