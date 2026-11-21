// «الأقسام» (ADR-093 amendment; the owner, 21 Nov 2026): each category's
// section is the owner's. A category with none shows the server's suggestion
// in its field -- saved only when «حفظ» is pressed; a section already set is
// what its field says; only what differs is sent, at once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/item_sections_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Api extends ApiService {
  final sent = <List<Map<String, dynamic>>>[];
  final deleted = <int>[];

  List<Map<String, dynamic>> sections = [
    {'id': 1, 'name': 'أساور', 'sort_order': 0, 'is_active': true,
     'categories': [{'id': 33, 'name': 'سوار ذهب 21', 'karat': '21'}]},
    {'id': 2, 'name': 'فارغ', 'sort_order': 0, 'is_active': true, 'categories': []},
  ];

  @override
  Future<Map<String, dynamic>> itemSections() async => {'sections': sections};

  @override
  Future<Map<String, dynamic>> itemSectionSuggestions() async => {
    'categories': [
      {'category_id': 33, 'category_name': 'سوار ذهب 21', 'karat': '21', 'is_active': true, 'section_id': 1,
       'suggested': 'سوار ذهب'},
      {'category_id': 34, 'category_name': 'سوار ذهب 18', 'karat': '18', 'is_active': true, 'section_id': null,
       'suggested': 'سوار ذهب'},
      {'category_id': 47, 'category_name': 'عقد ذهب (ناعم) 21', 'karat': '21', 'is_active': true,
       'section_id': null, 'suggested': 'عقد ذهب'},
    ],
  };

  @override
  Future<Map<String, dynamic>> assignItemSections(List<Map<String, dynamic>> assignments) async {
    sent.add(assignments);
    return {'sections': sections};
  }

  @override
  Future<Map<String, dynamic>> deleteItemSection(int id) async {
    deleted.add(id);
    return {'message': 'حُذف القسم'};
  }
}

Future<void> _open(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: ItemSectionsScreen(api: api)));
  await tester.pumpAndSettle();
}

String _field(WidgetTester tester, int id) =>
    tester.widget<TextField>(find.byKey(Key('section-field-$id'))).controller!.text;

void main() {
  testWidgets('a section set is its field; one not set shows the suggestion, said so, not saved', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(_field(tester, 33), 'أساور', reason: 'its section as set, not the suggestion');
    expect(_field(tester, 34), 'سوار ذهب');
    expect(find.text('مقترح — يُحفظ إن حفظت'), findsNWidgets(2));
    expect(api.sent, isEmpty, reason: 'nothing saved before «حفظ»');
    expect(find.text('حفظ (2)'), findsOneWidget);
  });

  testWidgets('the owner changes the suggestion; only what differs is sent, at once', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('section-pick-34')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('أساور').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('section-field-47')), '  عقود  ');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sections-save')));
    await tester.pumpAndSettle();
    expect(api.sent.single, [
      {'category_id': 34, 'section_name': 'أساور'},
      {'category_id': 47, 'section_name': 'عقود'},
    ], reason: '33 is as it was: not sent; spaces are the typing');
  });

  testWidgets('a field emptied takes its section away; only an empty section is deleted', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('section-field-33')), '');
    await tester.enterText(find.byKey(const Key('section-field-34')), '');
    await tester.enterText(find.byKey(const Key('section-field-47')), '');
    await tester.pump();
    await tester.tap(find.byKey(const Key('sections-save')));
    await tester.pumpAndSettle();
    expect(api.sent.single, [{'category_id': 33, 'section_name': ''}]);
    final full = tester.widget<InputChip>(find.byKey(const Key('section-1')));
    final empty = tester.widget<InputChip>(find.byKey(const Key('section-2')));
    expect((full.onDeleted, empty.onDeleted == null), (null, false));
  });
}
