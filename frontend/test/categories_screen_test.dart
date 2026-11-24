// The categories, a screen of their own (the owner, 24 Nov 2026: «شاشة إدارة
// التصنيفات برأيك ألا تحتاج شاشة وليس ديالوج؟»). Before: a 500-px dialog of
// 44 categories, no search, no filter, each edit a dialog upon it, the section
// not settable from it. Now: a table on a wide screen, cards on a phone;
// searched and filtered by karat, section, tracking and state; edited beside
// the table, or on a page of its own on a phone; a used category refused
// deletion is offered «أوقفه». Nothing overflows; nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/categories_screen.dart';
import 'package:frontend/theme/app_theme.dart';

import 'support/dark_text.dart';

Map<String, dynamic> _c(int id, String name, String karat,
        {int? section, String? sectionName, int items = 0, bool active = true, bool scrap = false,
        double? wage, String tracking = 'weight', int? system}) =>
    {
      'id': id, 'name': name, 'karat': karat, 'description': null, 'default_wage': wage, 'items_count': items,
      'is_active': active, 'is_scrap': scrap, 'tracking': tracking, 'size_system_id': system,
      'section_id': section, 'section_name': sectionName,
    };

class _Api extends ApiService {
  final added = <Map<String, dynamic>>[];
  final updated = <(int, Map<String, dynamic>)>[];
  final deleted = <int>[];
  bool includeInactiveAsked = false;

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async {
    includeInactiveAsked = includeInactive;
    return [
      _c(1, 'خواتم 21', '21', section: 1, sectionName: 'الخواتم', items: 12, wage: 15.5, system: 1),
      _c(2, 'خواتم 18', '18', section: 1, sectionName: 'الخواتم', items: 4),
      _c(3, 'سلاسل 21', '21', section: 2, sectionName: 'السلاسل', items: 0, tracking: 'piece'),
      _c(4, 'كسر 21', '21', scrap: true, items: 30),
      _c(5, 'ليرات 24', '24', active: false),
    ];
  }

  @override
  Future<Map<String, dynamic>> itemSections() async => {
    'sections': [
      {'id': 1, 'name': 'الخواتم', 'categories': []},
      {'id': 2, 'name': 'السلاسل', 'categories': []},
    ],
  };

  @override
  Future<List<Map<String, dynamic>>> getSizeSystems() async => [
    {'id': 1, 'name': 'مقاسات الخواتم', 'sizes': [], 'categories': []},
  ];

  @override
  Future<Map<String, dynamic>> addCategory(Map<String, dynamic> categoryData) async {
    added.add(categoryData);
    return {..._c(9, '${categoryData['name']}', '${categoryData['karat']}')};
  }

  @override
  Future<Map<String, dynamic>> updateCategory(int id, Map<String, dynamic> categoryData) async {
    updated.add((id, categoryData));
    return _c(id, 'x', '21');
  }

  @override
  Future<void> deleteCategory(int id) async {
    if (id == 1) throw ApiException.text('«خواتم 21» مستعمل في فواتير أو أصناف: أوقفه بدل حذفه');
    deleted.add(id);
  }
}

const _sizes = {'wide': Size(1600, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<_Api> open(WidgetTester tester, Size size, {bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: CategoriesScreen(api: api),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> edit(WidgetTester tester, int id) async {
    await tester.tap(find.byKey(Key('category-menu-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل').last);
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the list and the form fit and read', (tester) async {
        await open(tester, size, dark: dark);
        expect(tester.takeException(), isNull, reason: 'the list overflows');
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await edit(tester, 1);
        expect(tester.takeException(), isNull, reason: 'the form overflows');
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('the stopped ones are listed too, and a wide screen is a table', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    expect(api.includeInactiveAsked, isTrue);
    expect(find.byKey(const Key('app-table')), findsOneWidget);
    expect(find.byKey(const Key('category-row-5')), findsOneWidget);
    expect(find.text('موقوف'), findsOneWidget);
    expect(find.text('كسر'), findsOneWidget);
  });

  testWidgets('a phone: cards, not a table', (tester) async {
    await open(tester, _sizes['phone']!);
    expect(find.byKey(const Key('app-table')), findsNothing);
    expect(find.byKey(const Key('category-card-1')), findsOneWidget);
  });

  testWidgets('searched by name, filtered by karat and by state', (tester) async {
    await open(tester, _sizes['wide']!);
    await tester.enterText(find.byKey(const Key('categories-search')), 'خواتم');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category-row-1')), findsOneWidget);
    expect(find.byKey(const Key('category-row-3')), findsNothing);
    await tester.tap(find.byKey(const Key('categories-karat-18')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category-row-1')), findsNothing);
    expect(find.byKey(const Key('category-row-2')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('categories-search')), '');
    await tester.tap(find.byKey(const Key('categories-karat-18')));
    await tester.tap(find.text('الموقوفة'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('category-row-5')), findsOneWidget);
    expect(find.byKey(const Key('category-row-1')), findsNothing);
  });

  testWidgets('edited beside the table: its section, tracking and state sent as changed', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await tester.tap(find.byKey(const Key('category-row-2')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('app-table')), findsOneWidget, reason: 'the table stays beside the form');
    await tester.tap(find.byKey(const Key('category-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('السلاسل').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('بالقطعة').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-save')));
    await tester.pumpAndSettle();
    final (id, body) = api.updated.single;
    expect(id, 2);
    expect(body['section_id'], 2);
    expect(body['tracking'], 'piece');
    expect(body.containsKey('is_active'), isFalse, reason: 'unchanged, not sent');
    expect(body['karat'], '18');
  });

  testWidgets('a new one: its name and karat, then what an edit sets', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await tester.tap(find.byKey(const Key('category-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('category-name')), 'أساور 22');
    await tester.tap(find.text('22').last);
    await tester.tap(find.byKey(const Key('category-section')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الخواتم').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-save')));
    await tester.pumpAndSettle();
    expect(api.added.single['name'], 'أساور 22');
    expect(api.added.single['karat'], '22');
    expect(api.updated.single.$2['section_id'], 1);
  });

  testWidgets('a phone edits on a page of its own', (tester) async {
    await open(tester, _sizes['phone']!);
    await edit(tester, 3);
    expect(find.byKey(const Key('category-form-title')), findsOneWidget);
    expect(find.byKey(const Key('category-card-3')), findsNothing, reason: 'a page, not beside the list');
  });

  testWidgets('a used one refused deletion is offered «أوقفه»', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await tester.tap(find.byKey(const Key('category-menu-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('category-delete-confirm')));
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);
    expect(find.textContaining('أوقفه بدل حذفه'), findsOneWidget);
    await tester.tap(find.text('أوقفه'));
    await tester.pumpAndSettle();
    expect(api.updated.single.$1, 1);
    expect(api.updated.single.$2, {'is_active': false});
  });

  test('items said as Arabic counts them', () {
    expect([for (final n in [0, 1, 2, 3, 10, 11, 12]) itemsLabel(n)],
        ['بلا أصناف', 'صنف واحد', 'صنفان', '3 أصناف', '10 أصناف', '11 صنفًا', '12 صنفًا']);
  });
}
