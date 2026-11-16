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
        {String state = 'in_stock', double? wage, String? tag, double stones = 0, String? place = 'المعرض'}) =>
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
    String state = 'in_stock',
    String sort = 'number',
    bool ascending = false,
    int page = 1,
    int perPage = 25,
    ApiCancelToken? cancel,
  }) async {
    asked.add({'q': q, 'category': categoryId, 'karat': karat, 'place': safeBoxId, 'state': state, 'sort': sort,
               'asc': ascending, 'page': page});
    if (fail) throw ApiException.text('الخادم لا يجيب');
    final list = pieces ??
        [
          _piece('KJ-000241', 'بنجرة حرير', 12.4, wage: 160, tag: 'EPC1'),
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

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
        {'id': 3, 'name': 'بنجرة ذهب 21', 'tracking': 'piece'},
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
  Future<Map<String, dynamic>> updateItem(int id, Map<String, dynamic> itemData) async {
    edits.add({'id': id, ...itemData});
    return {'result': 'success'};
  }

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
                              'sort': 'number', 'asc': false, 'page': 1});
    final table = tester.widget<DataTable>(find.byKey(const Key('pieces-table')));
    DataRow row(String code) => table.rows.firstWhere((r) => r.key == ValueKey('piece-row-$code'));
    bool says(DataRow r, String text) => r.cells.any((c) =>
        find.descendant(of: find.byWidget(c.child), matching: find.text(text), matchRoot: true).evaluate().isNotEmpty);
    for (final said in ['KJ-000238', '56.00 جم', '1.20 جم', '2,184 ر.س', '39.00 للجرام', 'المعرض', 'في المخزون',
                        '03/01/2027', 'المورد أ', 'مربوطة']) {
      expect(says(row('KJ-000238'), said), isTrue, reason: said);
    }
    expect(says(row('KJ-000233'), 'بانتظار الفاتورة'), isTrue);
    expect(says(row('KJ-000233'), 'بلا رقاقة'), isTrue);
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
    await tester.tap(find.text('تعديل الاسم والوصف'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-edit-name')), 'بنجرة حرير ناعمة');
    await tester.enterText(find.byKey(const Key('piece-edit-description')), 'نقش يدوي');
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(api.edits.single, {'id': 241, 'name': 'بنجرة حرير ناعمة', 'description': 'نقش يدوي'},
        reason: 'its name and description, nothing of its receiving');
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
}
