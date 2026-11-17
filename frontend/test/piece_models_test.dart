// «الموديلات» (ADR-093 M1; the owner, 17 Nov 2026): a model its pieces share
// -- its photo, its expected wage, the sizes it comes in. The photo is sized
// down on the device with a thumbnail for the lists, both sent to the
// attachments' store and named by their ids -- never text (ADR-094); the sizes are its
// category's size system's; the expected wage is said to be the invoice's
// comparison, never a piece's wage; once a piece is of it its category stays
// and it is stopped, not deleted.

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/piece_model_form_screen.dart';
import 'package:frontend/screens/piece_models_screen.dart';
import 'package:image/image.dart' as img;

Uint8List _png(int w, int h) => Uint8List.fromList(img.encodePng(img.Image(width: w, height: h)));

const _bangles = {'id': 3, 'name': 'بنجرة ذهب 21', 'is_scrap': false, 'size_system_id': 1};
const _sets = {'id': 4, 'name': 'طقم ذهب 21', 'is_scrap': false, 'size_system_id': null};
const _scrap = {'id': 5, 'name': 'كسر 21', 'is_scrap': true, 'size_system_id': null};

Map<String, dynamic> _sun({int pieces = 9, bool active = true}) => {
      'id': 7,
      'name': 'بنجرة الشمس',
      'category': {'id': 3, 'name': 'بنجرة ذهب 21', 'size_system_id': 1},
      'supplier_code': 'SUP-A-118',
      'expected_wage_per_gram': 39.0,
      'has_stones': false,
      'is_active': active,
      'sizes': [
        {'id': 11, 'label': '17', 'position': 1},
        {'id': 12, 'label': '18', 'position': 2},
      ],
      'thumbnail': null,
      'has_photo': false,
      'photo': null,
      'pieces': pieces,
    };

class _FakeApi extends ApiService {
  _FakeApi({this.models = const [], this.model});

  final List<Map<String, dynamic>> models;
  final Map<String, dynamic>? model;
  final created = <Map<String, dynamic>>[];
  final updated = <Map<String, dynamic>>[];
  final sent = <String>[];

  @override
  Future<Map<String, dynamic>> uploadAttachment(List<int> bytes,
      {String role = 'scrap_gold_photo', String filename = 'photo.jpg'}) async {
    sent.add(role);
    return {'id': 60 + sent.length};
  }

  final read = <int>[];

  @override
  Future<Uint8List> attachmentBytes(int id) async {
    read.add(id);
    return _png(24, 18);
  }

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [_bangles, _sets, _scrap];

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
  Future<List<Map<String, dynamic>>> getPieceModels({int? categoryId, String? q, bool includeInactive = false}) async =>
      models;

  @override
  Future<Map<String, dynamic>> getPieceModel(int id) async => model!;

  @override
  Future<Map<String, dynamic>> createPieceModel(Map<String, dynamic> body) async {
    created.add(body);
    return {...body, 'id': 8};
  }

  @override
  Future<Map<String, dynamic>> updatePieceModel(int id, Map<String, dynamic> body) async {
    updated.add(body);
    return model!;
  }
}

Future<void> _pump(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: Directionality(textDirection: TextDirection.rtl, child: screen)));
  await tester.pumpAndSettle();
}

void main() {
  test('the photo is sized down with a thumbnail; what is not an image is said', () {
    final pair = modelPhotoPair(_png(2400, 1200))!;
    expect(img.findDecoderForData(pair.photo), isA<img.JpegDecoder>());
    final photo = img.decodeImage(pair.photo)!;
    final thumb = img.decodeImage(pair.thumbnail)!;
    expect((photo.width, photo.height), (photoSide, 600));
    expect((thumb.width, thumb.height), (thumbnailSide, 120));
    expect(modelPhotoPair(Uint8List.fromList([1, 2, 3])), isNull);
  });

  testWidgets('no model yet: says what a model is, and makes the first', (tester) async {
    await _pump(tester, PieceModelsScreen(api: _FakeApi()));
    expect(find.text('لا موديلات بعد'), findsOneWidget);
    expect(find.byKey(const Key('models-new')), findsOneWidget);
  });

  testWidgets('a model card: its name, wage, pieces and sizes; a stopped one says so', (tester) async {
    await _pump(tester, PieceModelsScreen(api: _FakeApi(models: [_sun(), {..._sun(), 'id': 9, 'is_active': false}])));
    expect(find.text('أجرة متوقّعة 39.0 للجرام · 9 قطعة'), findsNWidgets(2));
    expect(find.text('17'), findsNWidgets(2));
    expect(find.text('موقوف'), findsOneWidget);
  });

  testWidgets('a new model: its photo, its category\'s sizes, the wage said as a comparison', (tester) async {
    final api = _FakeApi();
    await _pump(tester, PieceModelFormScreen(api: api, categoryId: 3, pickPhoto: (_) async => _png(300, 200)));
    expect(find.byKey(const Key('model-wage-note')), findsOneWidget);
    expect(find.text('من نظام «مقاسات البناجر»'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('model-name')), 'بنجرة المفتول');
    await tester.enterText(find.byKey(const Key('model-wage')), '32');
    await tester.tap(find.byKey(const Key('model-size-12')));
    await tester.tap(find.byKey(const Key('model-size-13')));
    await tester.tap(find.byKey(const Key('model-photo')));
    await tester.pumpAndSettle();
    expect(find.text('تغيير الصورة'), findsOneWidget);
    await tester.tap(find.byKey(const Key('model-save')));
    await tester.pumpAndSettle();
    final body = api.created.single;
    expect((body['category_id'], body['name'], body['expected_wage_per_gram']), (3, 'بنجرة المفتول', '32'));
    expect((body['size_ids'] as List).toSet(), {12, 13});
    expect(api.sent, ['model_photo', 'model_thumbnail'], reason: 'both sent to the store');
    expect((body['photo_id'], body['thumbnail_id']), (61, 62));
    expect(body.values.whereType<String>().where((v) => v.startsWith('data:')), isEmpty, reason: 'never text');
  });

  testWidgets('a category with no size system says where to choose one', (tester) async {
    await _pump(tester, PieceModelFormScreen(api: _FakeApi(), categoryId: 4));
    expect(find.byKey(const Key('model-no-system')), findsOneWidget);
    expect(find.byType(FilterChip), findsNothing);
  });

  testWidgets('a model pieces are of: its category stays, it is stopped not deleted, its photo kept', (tester) async {
    final api = _FakeApi(model: _sun());
    await _pump(tester, PieceModelFormScreen(api: api, modelId: 7));
    final category = tester.widget<DropdownButtonFormField<int>>(find.byKey(const Key('model-category')));
    expect(category.onChanged, isNull);
    expect(find.byKey(const Key('model-delete')), findsNothing);
    expect(find.byKey(const Key('model-stop')), findsOneWidget);
    await tester.tap(find.byKey(const Key('model-save')));
    await tester.pumpAndSettle();
    expect(api.updated.single.containsKey('photo_id'), isFalse, reason: 'an unchanged photo is not sent again');
  });

  testWidgets('a model\'s photo is read through the server, once however often it is shown', (tester) async {
    ModelImage.forgetRead();
    final api = _FakeApi();
    await tester.pumpWidget(MaterialApp(
      home: Column(children: [
        SizedBox(height: 120, child: ModelImage(api: api, attachmentId: 62)),
        SizedBox(height: 120, child: ModelImage(api: api, attachmentId: 62)),
      ]),
    ));
    await tester.pumpAndSettle();
    expect(api.read, [62]);
    expect(find.byType(Image), findsNWidgets(2));
  });
}
