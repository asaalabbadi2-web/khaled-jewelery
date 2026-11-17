// The models board and the sizes grid (ADR-093 M4; the owner, 17 Nov 2026):
// a category chosen, each model's stock size by size -- a size with nothing
// red, what has run out said -- and «بلا موديل» beside them, the line adding
// up to the category's stock in the server's figures; a model's sizes opened,
// each size's pieces lightest first with their place.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/model_stock_grid_screen.dart';
import 'package:frontend/screens/piece_models_screen.dart';

const _sun = {
  'id': 5, 'name': 'بنجرة الشمس', 'supplier_code': 'SUP-A-118', 'expected_wage_per_gram': 39.0, 'is_active': true,
  'category': {'id': 3, 'name': 'بنجرة ذهب 21'}, 'thumbnail': null, 'pieces': 2,
  'sizes': [
    {'id': 11, 'label': '17', 'position': 1},
    {'id': 12, 'label': '18', 'position': 2},
  ],
  'stock': {'count': 2, 'weight': 22.25},
  'by_size': [
    {'size': {'id': 11, 'label': '17'}, 'count': 0, 'weight': 0.0, 'lightest': null, 'heaviest': null},
    {'size': {'id': 12, 'label': '18'}, 'count': 2, 'weight': 22.25, 'lightest': 10.9, 'heaviest': 11.35},
  ],
  'missing': ['17'],
};

class _Api extends ApiService {
  final asked = <String>[];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
        {'id': 3, 'name': 'بنجرة ذهب 21', 'is_scrap': false, 'size_system_id': 1},
      ];

  @override
  Future<List<Map<String, dynamic>>> getPieceModels({int? categoryId, String? q, bool includeInactive = false}) async =>
      [Map<String, dynamic>.from(_sun)..remove('by_size')];

  @override
  Future<Map<String, dynamic>> getModelsBoard(int categoryId) async {
    asked.add('board $categoryId');
    return {
      'category': {'id': 3, 'name': 'بنجرة ذهب 21', 'size_system_id': 1},
      'sizes': [
        {'id': 11, 'label': '17'},
        {'id': 12, 'label': '18'},
        {'id': 13, 'label': '19'},
      ],
      'in_stock': {'count': 4, 'weight': 26.75},
      'in_models': {'count': 2, 'weight': 22.25},
      'models_count': 1,
      'models': [_sun],
      'no_model': {
        'count': 2, 'weight': 4.5,
        'by_size': [
          {'size': {'id': 13, 'label': '19'}, 'count': 1, 'weight': 3.0},
          {'size': null, 'count': 1, 'weight': 1.5},
        ],
      },
    };
  }

  @override
  Future<Map<String, dynamic>> getStockGrid({int? modelId, int? categoryId}) async {
    asked.add('grid $modelId $categoryId');
    return {
      'category': {'id': 3, 'name': 'بنجرة ذهب 21'},
      'model': _sun,
      'stock': {'count': 2, 'weight': 22.25},
      'by_size': [
        {'size': {'id': 11, 'label': '17'}, 'count': 0, 'weight': 0.0, 'pieces': []},
        {
          'size': {'id': 12, 'label': '18'}, 'count': 2, 'weight': 22.25, 'lightest': 10.9, 'heaviest': 11.35,
          'pieces': [
            {'id': 2, 'item_code': 'KJ-000242', 'weight': 10.9, 'location': {'id': 7, 'name': 'المعرض'}},
            {'id': 1, 'item_code': 'KJ-000241', 'weight': 11.35, 'location': {'id': 8, 'name': 'الخزينة'}},
          ],
        },
      ],
    };
  }
}

Future<void> _pump(WidgetTester tester, Widget screen, {Size size = const Size(1280, 1100)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: screen)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('no category: the models\' list, and the way to their stock', (tester) async {
    final api = _Api();
    await _pump(tester, PieceModelsScreen(api: api));
    expect(find.text('اختر تصنيفًا لترى ما في المخزون من كل موديل ومقاس.'), findsOneWidget);
    expect(api.asked, isEmpty);
  });

  testWidgets('a category: its line adds up, each size its pieces, the run out said, «بلا موديل» beside', (tester) async {
    final api = _Api();
    await _pump(tester, PieceModelsScreen(api: api));
    await tester.tap(find.byKey(const Key('models-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(api.asked, ['board 3']);
    expect(find.text('2 قطعة في 1 موديلات + 2 بلا موديل = 4 قطعة · 26.75 جم — رصيد التصنيف'), findsOneWidget);
    expect(find.text('17 · 0'), findsOneWidget);
    expect(find.text('18 · 2'), findsOneWidget);
    expect(find.byKey(const Key('model-missing-5')), findsOneWidget);
    expect(find.text('نفد: 17'), findsOneWidget);
    expect(find.byKey(const Key('board-no-model')), findsOneWidget);
    expect(find.text('بلا مقاس · 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('model-sizes-5')));
    await tester.pumpAndSettle();
    expect(find.byType(ModelStockGridScreen), findsOneWidget);
  });

  testWidgets('the grid: a size run out says so; a size opened, its pieces lightest first with their place',
      (tester) async {
    await _pump(tester, ModelStockGridScreen(api: _Api(), modelId: 5, title: 'بنجرة الشمس'));
    expect(find.text('2 قطعة · 22.25 جم'), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('grid-size-11')), matching: find.text('نفد')), findsOneWidget);
    await tester.tap(find.byKey(const Key('grid-size-12')));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.byKey(const Key('grid-piece-KJ-000242'))).dy;
    final second = tester.getTopLeft(find.byKey(const Key('grid-piece-KJ-000241'))).dy;
    expect(first < second, isTrue, reason: 'lightest first, as the server sends');
    expect(find.text('المعرض'), findsOneWidget);
    expect(find.text('الخزينة'), findsOneWidget);
  });

  testWidgets('on a phone the board fits: nothing past its edge', (tester) async {
    await _pump(tester, PieceModelsScreen(api: _Api()), size: const Size(360, 1800));
    await tester.tap(find.byKey(const Key('models-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('board-no-model')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
