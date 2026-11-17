// «أنظمة المقاسات» (ADR-093 M0; the owner, 17 Nov 2026): «مقاسات البناجر
// عندنا 17، 18، 19 وهكذا ... هناك عدة أنظمة للمقاسات». A system's sizes in
// their order with what each holds, the categories that follow it; a size a
// piece holds cannot be deleted here; the server's refusal is said as it
// says it; nothing yet, the way to make the first.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/size_systems_screen.dart';

Map<String, dynamic> _bangles() => {
      'id': 1,
      'name': 'مقاسات البناجر',
      'measurement_label': 'القطر الداخلي — مم',
      'sizes': [
        {'id': 11, 'label': '17', 'position': 1, 'measurement': null, 'pieces': 7},
        {'id': 12, 'label': '18', 'position': 2, 'measurement': 58.5, 'pieces': 0},
      ],
      'categories': [
        {'id': 3, 'name': 'بنجرة ذهب 21'},
        {'id': 4, 'name': 'بنجرة ذهب 18'},
      ],
    };

class _FakeApi extends ApiService {
  _FakeApi(this.systems, {this.refuseAdd = false});

  List<Map<String, dynamic>> systems;
  final bool refuseAdd;
  final calls = <String>[];

  @override
  Future<List<Map<String, dynamic>>> getSizeSystems() async => systems;

  @override
  Future<Map<String, dynamic>> createSizeSystem({
    required String name,
    String? measurementLabel,
    List<String> sizes = const [],
  }) async {
    calls.add('create $name|$measurementLabel');
    final made = {'id': 9, 'name': name, 'measurement_label': measurementLabel, 'sizes': [], 'categories': []};
    systems = [...systems, made];
    return made;
  }

  @override
  Future<Map<String, dynamic>> addSize(int systemId, {required String label, String? measurement}) async {
    calls.add('add $systemId $label|$measurement');
    if (refuseAdd) {
      throw const ApiException(
          statusCode: 400, code: 'size_label_taken', message: 'المقاس 18 موجود في «مقاسات البناجر»');
    }
    return systems.first;
  }

  @override
  Future<Map<String, dynamic>> deleteSize(int sizeId) async {
    calls.add('delete $sizeId');
    return systems.first;
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api) async {
  await tester.pumpWidget(MaterialApp(
    home: Directionality(textDirection: TextDirection.rtl, child: SizeSystemsScreen(api: api)),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('nothing yet: says so, and makes the first', (tester) async {
    final api = _FakeApi([]);
    await _pump(tester, api);
    expect(find.text('لا أنظمة مقاسات بعد'), findsOneWidget);
    await tester.tap(find.byKey(const Key('size-system-new')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('size-system-name')), 'مقاسات البناجر');
    await tester.enterText(find.byKey(const Key('size-system-unit')), 'القطر الداخلي — مم');
    await tester.tap(find.byKey(const Key('size-system-save')));
    await tester.pumpAndSettle();
    expect(api.calls, ['create مقاسات البناجر|القطر الداخلي — مم']);
    expect(find.text('لا مقاسات في هذا النظام'), findsOneWidget);
  });

  testWidgets('a system: its sizes in order, what each holds, who follows it', (tester) async {
    final api = _FakeApi([_bangles()]);
    await _pump(tester, api);
    expect(find.text('يتبعه: بنجرة ذهب 21 · بنجرة ذهب 18'), findsOneWidget);
    expect(find.text('تحمله 7 قطعة'), findsOneWidget);
    expect(find.text('القطر الداخلي — مم: 58.5 · لا تحمله قطعة'), findsOneWidget);
    final labels = tester.widgetList<Text>(find.descendant(
        of: find.byType(ReorderableListView), matching: find.byType(Text)))
        .map((t) => t.data)
        .where((d) => d == '17' || d == '18')
        .toList();
    expect(labels, ['17', '18'], reason: 'in their order');
    final held = tester.widget<IconButton>(find.byKey(const Key('size-delete-11')));
    expect(held.onPressed, isNull, reason: 'a size a piece holds is not deleted');
    await tester.tap(find.byKey(const Key('size-delete-12')));
    await tester.pumpAndSettle();
    expect(api.calls, ['delete 12']);
  });

  testWidgets('a size added is sent as typed; the server refusal is said as it says it', (tester) async {
    final api = _FakeApi([_bangles()], refuseAdd: true);
    await _pump(tester, api);
    await tester.tap(find.byKey(const Key('size-add')));
    await tester.pumpAndSettle();
    expect(find.text('القطر الداخلي — مم (اختياري)'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('size-label')), '١٨');
    await tester.enterText(find.byKey(const Key('size-measurement')), '58,5');
    await tester.tap(find.byKey(const Key('size-save')));
    await tester.pumpAndSettle();
    expect(api.calls, ['add 1 ١٨|58,5'], reason: 'the one spelling is the server\'s');
    expect(find.text('المقاس 18 موجود في «مقاسات البناجر»'), findsOneWidget);
  });
}
