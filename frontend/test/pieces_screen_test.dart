// «القطع» (the owner, 16 Nov 2026; ADR-087): the pieces' list the server
// searches, filters, sorts and pages -- a table on a computer, cards on a
// phone, a piece's card with its receiving's facts, and its name and
// description the only things edited. The items' list while receiving is
// off; the pieces' once it works -- one door.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/items_or_pieces_screen.dart';
import 'package:frontend/screens/items_screen_enhanced.dart';
import 'package:frontend/screens/pieces_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _piece(String code, String name, double weight,
        {String state = 'in_stock', double? wage, String? tag, double stones = 0, String? place = 'المعرض',
        Map<String, dynamic>? model, Map<String, dynamic>? size}) =>
    {
      'id': int.parse(code.substring(3)),
      'item_code': code,
      'barcode': code,
      'name': name,
      'description': null,
      'karat': '21',
      'weight': weight,
      'stones_weight': stones,
      'wage': wage,
      'wage_known': wage != null,
      'tag': tag,
      'state': state,
      'in_stock': state == 'in_stock',
      'location': place == null ? null : {'id': 7, 'name': place},
      'left_at': state == 'in_stock' ? null : '2026-11-10',
      'category_id': 3,
      'category_name': 'بنجرة ذهب 21',
      'model': model,
      'size': size,
      'received': {
        'kind': 'receipt',
        'date': '2027-01-03',
        'document': 'REC-2027-00012',
        'invoice_id': 40,
        'supplier_name': 'المورد أ'
      },
    };

class _FakeApi extends ApiService {
  _FakeApi({this.pieces, this.fail = false});

  final List<Map<String, dynamic>>? pieces;
  final bool fail;
  final asked = <Map<String, Object?>>[];
  final edits = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> getPieces({
    String? q,
    int? categoryId,
    int? karat,
    int? safeBoxId,
    String? modelId,
    String? sizeId,
    String state = 'in_stock',
    bool untagged = false,
    String sort = 'number',
    bool ascending = false,
    int page = 1,
    int perPage = 25,
    ApiCancelToken? cancel,
  }) async {
    asked.add({'q': q, 'category': categoryId, 'karat': karat, 'place': safeBoxId, 'state': state, 'sort': sort,
               'asc': ascending, 'page': page, 'model': modelId, 'size': sizeId, 'untagged': untagged});
    if (fail) throw ApiException.text('الخادم لا يجيب');
    final list = pieces ??
        [
          _piece('KJ-000241', 'بنجرة حرير', 12.4, wage: 160, tag: 'EPC1',
              model: {'id': 5, 'name': 'بنجرة الشمس'}, size: {'id': 12, 'label': '18'}),
          _piece('KJ-000238', 'طقم شمس بعقد وحلق وتصميم طويل الاسم', 56, wage: 2184, stones: 1.2, tag: 'EPC2'),
          _piece('KJ-000233', 'خاتم وتر', 4.1),
        ];
    return {
      'pieces': list,
      'total': 186,
      'page': page,
      'per_page': perPage,
      'summary': {'in_stock_count': list.isEmpty ? 0 : 186, 'in_stock_weight': 2412.6, 'in_stock_untagged': 12, 'sold_this_month': 41},
    };
  }

  // Its label (ADR-097 ط4): each request recorded; the printer answers as told.
  final printed = <Map<String, dynamic>>[];
  String printOutcome = 'completed';
  String? stopCode;
  int _job = 0;

  @override
  Future<Map<String, dynamic>> labelPreview(int pieceId) async => {
        'faces': {'code': 'KJ-000$pieceId', 'number': 'KJ-000$pieceId', 'facts': '21K · 10.00g',
                  'name': 'بنجرة أ', 'marks': null},
      };

  @override
  Future<Map<String, dynamic>> printPieceLabel(int pieceId, Map<String, dynamic> body) async {
    printed.add({...body, 'piece_id': pieceId});
    final failed = printOutcome == 'failed';
    return {
      'job': {
        'id': ++_job, 'item_id': pieceId, 'kind': body['kind'], 'status': printOutcome,
        'last_attempt': {
          'id': 900 + _job, 'generation': 1, 'printed': !failed, 'written': !failed, 'verified': !failed,
          'error_code': failed ? stopCode : null,
          'message': failed ? 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة' : null,
        },
      },
    };
  }

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
        {'id': 3, 'name': 'بنجرة ذهب 21', 'tracking': 'piece', 'size_system_id': 1},
        {'id': 4, 'name': 'سلسال 21', 'tracking': 'weight'},
      ];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async =>
      [SafeBoxModel(id: 7, name: 'المعرض', safeType: 'gold', accountId: 70, stockLocation: 'showroom')];

  @override
  Future<Map<String, dynamic>> updatePiece(int id, Map<String, dynamic> body) async {
    edits.add({'id': id, ...body});
    return {'piece': {}, 'changed': {}};
  }

  @override
  Future<List<Map<String, dynamic>>> getPieceModels({int? categoryId, String? q, bool includeInactive = false}) async => [
        {
          'id': 5, 'name': 'بنجرة الشمس', 'is_active': true, 'category': {'id': 3, 'name': 'بنجرة ذهب 21'},
          'sizes': [
            {'id': 11, 'label': '17', 'position': 1},
            {'id': 12, 'label': '18', 'position': 2},
          ],
        },
      ];

  @override
  Future<List<Map<String, dynamic>>> getSizeSystems() async => [
        {
          'id': 1, 'name': 'مقاسات البناجر', 'categories': [],
          'sizes': [
            {'id': 11, 'label': '17', 'position': 1, 'pieces': 0},
            {'id': 12, 'label': '18', 'position': 2, 'pieces': 0},
            {'id': 13, 'label': '19', 'position': 3, 'pieces': 0},
          ],
        },
      ];

  @override
  Future<List<dynamic>> getItems({bool? inStockOnly, int? categoryId, int? excludeCategoryId}) async => [];
}

Future<void> _mount(WidgetTester tester, Widget screen, {Size size = const Size(1280, 900), bool receiving = true}) async {
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'auth_current_user': jsonEncode(AppUserModel.fromJson({
      'id': 3, 'username': 'manager', 'full_name': 'المدير', 'role': 'manager', 'is_active': true,
      'is_admin': false, 'employee_id': 15, 'effective_permissions': ['items.view', 'items.edit'],
      'permissions': null, 'must_change_password': false,
    }).toStorageMap()),
    'app_settings': jsonEncode({'main_karat': 21, 'receiving_active': receiving}),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final auth = AuthProvider();
  await auth.init();
  await tester.pumpWidget(MultiProvider(
    providers: [
      ChangeNotifierProvider<AuthProvider>.value(value: auth),
      ChangeNotifierProvider.value(value: settings),
    ],
    child: MaterialApp(
      theme: LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: screen,
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  testWidgets('one door: the items while receiving is off, the pieces once it works', (tester) async {
    await _mount(tester, ItemsOrPiecesScreen(api: _FakeApi()), receiving: false);
    expect(find.byType(ItemsScreenEnhanced), findsOneWidget);
    expect(find.byType(PiecesScreen), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await _mount(tester, ItemsOrPiecesScreen(api: _FakeApi()), receiving: true);
    expect(find.byType(PiecesScreen), findsOneWidget);
    expect(find.byType(ItemsScreenEnhanced), findsNothing);
  });

  testWidgets('a computer: the table, each piece its facts, state, place and receiving; the summary is the server\'s',
      (tester) async {
    final api = _FakeApi();
    await _mount(tester, PiecesScreen(api: api));
    expect(find.byKey(const Key('pieces-table')), findsOneWidget);
    expect(api.asked.single, {'q': '', 'category': null, 'karat': null, 'place': null, 'state': 'in_stock',
                              'sort': 'number', 'asc': false, 'page': 1, 'model': null, 'size': null,
                              'untagged': false});
    final table = tester.widget<DataTable>(find.byKey(const Key('pieces-table')));
    DataRow row(String code) => table.rows.firstWhere((r) => r.key == ValueKey('piece-row-$code'));
    bool says(DataRow r, String text) => r.cells.any((c) =>
        find.descendant(of: find.byWidget(c.child), matching: find.text(text), matchRoot: true).evaluate().isNotEmpty);
    for (final said in ['KJ-000238', '56.00 جم', '1.20 جم', '2,184 ر.س', '39.00 للجرام', 'المعرض', 'في المخزون',
                        '2027-01-03', 'المورد أ', 'رقاقة معتمدة']) {
      expect(says(row('KJ-000238'), said), isTrue, reason: said);
    }
    expect(says(row('KJ-000233'), 'بانتظار الفاتورة'), isTrue);
    expect(says(row('KJ-000233'), 'بلا بطاقة'), isTrue, reason: 'its label waiting (ADR-097)');
    expect(find.descendant(of: find.byKey(const Key('pieces-summary-in-stock')), matching: find.text('2,412.60')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('pieces-summary-untagged')), matching: find.text('12')),
        findsOneWidget);
    expect(find.text('الوزن المسجّل'), findsNothing, reason: 'the catalogue weights summed were not stock');
  });

  testWidgets('sorting and filtering ask the server, from the first page', (tester) async {
    final api = _FakeApi();
    await _mount(tester, PiecesScreen(api: api));
    await tester.tap(find.text('الوزن').first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.asked.last, containsPair('sort', 'weight'));
    await tester.tap(find.text('التالي'));
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.asked.last, containsPair('page', 2));
    await tester.tap(find.byKey(const Key('pieces-state')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بيعت').last);
    await tester.pumpAndSettle();
    expect(api.asked.last, allOf(containsPair('state', 'sold'), containsPair('page', 1)));
    await tester.enterText(find.byKey(const Key('pieces-search')), 'KJ-0002');
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.asked.last, allOf(containsPair('q', 'KJ-0002'), containsPair('page', 1)));
  });

  for (final (device, size) in [('an iPhone', const Size(390, 844)), ('an SE', const Size(375, 667)),
                                ('a 360 phone', const Size(360, 780))]) {
    testWidgets('a phone ($device): cards, nothing past its edge, nothing cut but a long name', (tester) async {
      await _mount(tester, PiecesScreen(api: _FakeApi()), size: Size(size.width, 2000));
      expect(find.byKey(const Key('pieces-table')), findsNothing);
      expect(find.byKey(const ValueKey('piece-card-KJ-000241')), findsOneWidget);
      expect(tester.takeException(), isNull);
      final cut = <String>[];
      for (final e in find.byType(RichText).evaluate()) {
        final p = e.renderObject! as RenderParagraph;
        if (p.didExceedMaxLines) cut.add(p.text.toPlainText());
      }
      expect(cut, isEmpty, reason: 'cut on $device: $cut');
    });
  }

  testWidgets('a piece\'s card says its facts; only its name and description are edited', (tester) async {
    final api = _FakeApi();
    await _mount(tester, PiecesScreen(api: api), size: const Size(390, 2000));
    await tester.tap(find.byKey(const ValueKey('piece-card-KJ-000241')));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('piece-card'));
    for (final said in ['12.40', 'بلا أحجار', '160 ر.س · 12.90 للجرام', 'المعرض', 'مربوطة', 'REC-2027-00012']) {
      expect(find.descendant(of: card, matching: find.text(said)), findsOneWidget, reason: said);
    }
    for (final said in ['بنجرة الشمس', '18']) {
      expect(find.descendant(of: card, matching: find.text(said)), findsOneWidget, reason: said);
    }
    await tester.tap(find.text('تعديل الوصف والموديل والمقاس'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-edit-name')), 'بنجرة حرير ناعمة');
    await tester.enterText(find.byKey(const Key('piece-edit-description')), 'نقش يدوي');
    await tester.tap(find.byKey(const Key('piece-edit-save')));
    await tester.pumpAndSettle();
    expect(api.edits.single,
        {'id': 241, 'name': 'بنجرة حرير ناعمة', 'description': 'نقش يدوي', 'model_id': 5, 'size_id': 12},
        reason: 'its words, nothing of its receiving');
  });

  testWidgets('no pieces yet: it says where a piece is born', (tester) async {
    await _mount(tester, PiecesScreen(api: _FakeApi(pieces: const [])));
    expect(find.text('القطعة تولد عند الاستلام، في «محطة ترميز القطع».'), findsOneWidget);
  });

  testWidgets('a first load that fails says so, and tries again', (tester) async {
    final api = _FakeApi(fail: true);
    await _mount(tester, PiecesScreen(api: api));
    expect(find.text('تعذّر تحميل القطع'), findsOneWidget);
  });

  testWidgets('a piece given a model: only the model\'s sizes offered; none takes its size away', (tester) async {
    final api = _FakeApi(pieces: [_piece('KJ-000250', 'بنجرة ذهب 21', 20.0, wage: 800)]);
    await _mount(tester, PiecesScreen(api: api));
    expect(tester.getRect(find.byKey(const Key('piece-actions-KJ-000250'))).left, greaterThanOrEqualTo(0),
        reason: 'its menu on the screen, not past its edge');
    await tester.tap(find.byKey(const Key('piece-actions-KJ-000250')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل الوصف والموديل والمقاس'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('piece-edit-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة الشمس').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('piece-edit-size-5')));
    await tester.pumpAndSettle();
    expect(find.text('19'), findsNothing, reason: 'the model comes in 17 and 18');
    await tester.tap(find.text('18').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('piece-edit-save')));
    await tester.pumpAndSettle();
    expect((api.edits.single['model_id'], api.edits.single['size_id']), (5, 12));
  });

  testWidgets('the table says each piece\'s model and size; the list filters by them', (tester) async {
    final api = _FakeApi();
    await _mount(tester, PiecesScreen(api: api));
    final table = tester.widget<DataTable>(find.byKey(const Key('pieces-table')));
    final labels = [for (final c in table.columns) ((c.label as Text).data)];
    expect(labels.sublist(1, 4), ['الاسم', 'الموديل', 'المقاس']);
    expect(find.text('بنجرة الشمس'), findsWidgets);
    await tester.tap(find.byKey(const Key('pieces-model')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بلا موديل').last);
    await tester.pumpAndSettle();
    expect(api.asked.last['model'], 'none');
    expect(find.byKey(const Key('pieces-size')), findsNothing, reason: 'a size is its category\'s: choose it first');
    await tester.tap(find.byKey(const Key('pieces-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pieces-size')), findsOneWidget);
    for (final door in ['pieces-models', 'pieces-size-systems', 'pieces-categories']) {
      expect(find.byKey(Key(door)), findsOneWidget, reason: door);
    }
  });

  // ── its label (ADR-097 ط4) ─────────────────────────────────────────────

  List<Map<String, dynamic>> waiting() => [
        _piece('KJ-000301', 'بنجرة أ', 10.0),
        _piece('KJ-000302', 'بنجرة ب', 11.0),
        _piece('KJ-000303', 'بنجرة ج', 12.0, tag: 'EPC3'),
      ];

  Future<void> choose(WidgetTester tester, String code) async {
    await tester.tap(find.byKey(Key('piece-select-$code')));
    await tester.pumpAndSettle();
  }

  testWidgets('«بلا بطاقة» asks the server for the pieces with no adopted tag', (tester) async {
    final api = _FakeApi();
    await _mount(tester, PiecesScreen(api: api));
    await tester.tap(find.byKey(const Key('pieces-untagged')));
    await tester.pumpAndSettle();
    expect((api.asked.last['untagged'], api.asked.last['page']), (true, 1));
  });

  testWidgets('«اطبع المحدد»: one after another through the engine, a printed one left', (tester) async {
    final api = _FakeApi(pieces: waiting());
    await _mount(tester, PiecesScreen(api: api));
    for (final code in ['KJ-000301', 'KJ-000302', 'KJ-000303']) {
      await choose(tester, code);
    }
    await tester.tap(find.byKey(const Key('pieces-print-selected')));
    await tester.pumpAndSettle();
    expect([for (final p in api.printed) p['piece_id']], [301, 302], reason: 'the tagged one not printed again');
    expect(api.printed.every((p) => p['run'] == true && p['kind'] == 'first'), isTrue);
    expect(api.printed.map((p) => p['request_key']).toSet(), hasLength(2), reason: 'a key each');
    expect(find.text('طُبعت 2 من 3 · تُركت 1 (مطبوعة أو تحتاج حسمًا)'), findsOneWidget);
  });

  testWidgets('«اطبع المحدد» stops at the printer\'s own stop: the rest not sent', (tester) async {
    final api = _FakeApi(pieces: waiting())
      ..printOutcome = 'failed'
      ..stopCode = 'paper_out';
    await _mount(tester, PiecesScreen(api: api));
    await choose(tester, 'KJ-000301');
    await choose(tester, 'KJ-000302');
    await tester.tap(find.byKey(const Key('pieces-print-selected')));
    await tester.pumpAndSettle();
    expect(api.printed, hasLength(1), reason: 'the next would fail as well');
    expect(find.textContaining('توقّفت الطباعة: انتهت الملصقات'), findsOneWidget);
  });

  testWidgets('a piece\'s menu prints through the engine; a printed one is reprinted with its reason',
      (tester) async {
    final api = _FakeApi(pieces: waiting());
    await _mount(tester, PiecesScreen(api: api));
    await tester.tap(find.byKey(const Key('piece-actions-KJ-000301')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('طباعة البطاقة'));
    await tester.pumpAndSettle();
    expect((api.printed.single['piece_id'], api.printed.single['kind']), (301, 'first'));
    expect(find.text('طباعة الباركود'), findsNothing, reason: 'not the items\' screen');
    await tester.tap(find.byKey(const Key('piece-actions-KJ-000303')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('طباعة البطاقة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('confirm-reason')), 'تلفت');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect((api.printed.last['piece_id'], api.printed.last['kind'], api.printed.last['reason']),
        (303, 'reprint', 'تلفت'));
  });

  testWidgets('a piece\'s card shows its label as it prints', (tester) async {
    final api = _FakeApi(pieces: waiting());
    await _mount(tester, PiecesScreen(api: api));
    await tester.tap(find.text('بنجرة أ').first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('label-preview-second')), findsOneWidget);
  });
}
