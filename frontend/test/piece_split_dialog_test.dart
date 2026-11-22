// «تفكيك القطعة» (ADR-099; the owner, 23 Nov 2026): each part weighed on its
// own, every answer the server's -- the shares, the total, the difference and
// where it goes, or why not -- «اعتماد» waiting for an answer and a reason;
// in the sale, which parts go into the invoice.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/piece_split_dialog.dart';

const _categories = [
  {'id': 1, 'name': 'عقد ذهب 21', 'karat': '21', 'tracking': 'weight', 'is_active': true, 'is_scrap': false},
  {'id': 2, 'name': 'حلق ذهب 21', 'karat': '21', 'tracking': 'weight', 'is_active': true, 'is_scrap': false},
  {'id': 3, 'name': 'اساور 21', 'karat': '21', 'tracking': 'piece', 'is_active': true, 'is_scrap': false},
  {'id': 4, 'name': 'عقد ذهب 18', 'karat': '18', 'tracking': 'weight', 'is_active': true, 'is_scrap': false},
  {'id': 5, 'name': 'كسر 21', 'karat': '21', 'tracking': 'weight', 'is_active': true, 'is_scrap': true},
  {'id': 6, 'name': 'حلق اسباني (موقوف)', 'karat': '21', 'tracking': 'weight', 'is_active': false, 'is_scrap': false},
];

const _names = {1: 'عقد ذهب 21', 2: 'حلق ذهب 21', 3: 'اساور 21'};

class _Api extends ApiService {
  final checked = <List<Map<String, dynamic>>>[];
  final made = <Map<String, dynamic>>[];
  final printed = <(int, bool)>[];

  @override
  Future<Map<String, dynamic>> printPieceLabel(int pieceId, Map<String, dynamic> body) async {
    printed.add((pieceId, body['run'] as bool));
    return {'job': {'id': 1, 'kind': 'first', 'status': body['run'] == true ? 'completed' : 'pending'}};
  }

  Map<String, dynamic> _view(List<Map<String, dynamic>> parts) {
    final total = parts.fold<double>(0, (s, p) => s + (p['weight'] as num));
    return {
      'grams': 40.0, 'total': total, 'difference': double.parse((total - 40).toStringAsFixed(3)), 'tolerance': 0.05,
      'wage': 1200.0,
      'parts': [
        for (final p in parts)
          {'category_id': p['category_id'], 'category_name': _names[p['category_id']], 'weight': p['weight'],
           'stones_weight': 0, 'wage': (p['wage'] as num?) ?? 1200 * (p['weight'] as num) / total},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> checkPieceSplit(int pieceId, List<Map<String, dynamic>> parts) async {
    checked.add(parts);
    final view = _view(parts);
    if (((view['difference'] as double)).abs() > 0.05) {
      return {'refused': {'code': 'split_weight_differs',
                          'message': 'مجموع الأجزاء ${view['total']} جم ووزن القطعة 40.00 جم: الفرق أكبر من المقبول'}};
    }
    return {'split': view};
  }

  @override
  Future<Map<String, dynamic>> splitPiece(int pieceId,
      {required List<Map<String, dynamic>> parts, required String reason, required String requestKey}) async {
    made.add({'piece_id': pieceId, 'parts': parts, 'reason': reason, 'request_key': requestKey});
    return {
      'split': {
        'id': 1, 'item_code': 'KJ-000123', 'entry_number': 'JE-2026-08000', 'difference': 0.0,
        'parts': [
          for (final p in parts)
            {'category_id': p['category_id'], 'category_name': _names[p['category_id']], 'weight': p['weight'],
             'wage': 300.0, 'piece_id': p['category_id'] == 3 ? 99 : null,
             'item_code': p['category_id'] == 3 ? 'KJ-000456' : null},
        ],
      },
    };
  }
}

PieceSplitDone? _result;

Future<void> _open(WidgetTester tester, _Api api, {bool choose = false}) async {
  _result = null;
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: LightTheme.theme,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () async => _result = await PieceSplitDialog.show(context,
                api: api, pieceId: 7, code: 'KJ-000123', grams: 40, karat: 21,
                categories: _categories, choose: choose),
            child: const Text('فتح'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('فتح'));
  await tester.pumpAndSettle();
}

Future<void> _part(WidgetTester tester, int n, String category, String weight) async {
  await tester.tap(find.byKey(Key('split-part-category-$n')));
  await tester.pumpAndSettle();
  await tester.tap(find.text(category).last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(Key('split-part-weight-$n')), weight);
  await tester.pump(PieceSplitDialog.askAfter);
  await tester.pumpAndSettle();
}

bool _confirmable(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('split-confirm'))).onPressed != null;

String _summary(WidgetTester tester) => tester
    .widget<Text>(find.descendant(of: find.byKey(const Key('split-summary')), matching: find.byType(Text)))
    .data!;

void main() {
  testWidgets('only the categories a part may go to are offered', (tester) async {
    await _open(tester, _Api());
    await tester.tap(find.byKey(const Key('split-part-category-0')));
    await tester.pumpAndSettle();
    for (final name in ['عقد ذهب 21', 'حلق ذهب 21', 'اساور 21']) {
      expect(find.text(name), findsWidgets, reason: name);
    }
    for (final name in ['عقد ذهب 18', 'كسر 21', 'حلق اسباني (موقوف)']) {
      expect(find.text(name), findsNothing, reason: '$name: another karat, scrap, or stopped');
    }
  });

  testWidgets('the server answers as they type; «اعتماد» waits for its answer and a reason', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(_confirmable(tester), isFalse);
    expect(_summary(tester), 'اختر تصنيف كل جزء واكتب وزنه');
    await _part(tester, 0, 'عقد ذهب 21', '30');
    expect(api.checked, isEmpty, reason: 'a part without its category or weight: nothing asked');
    await _part(tester, 1, 'اساور 21', '9.97');
    expect(api.checked.last, [
      {'category_id': 1, 'weight': 30.0, 'stones_weight': 0},
      {'category_id': 3, 'weight': 9.97, 'stones_weight': 0},
    ]);
    expect(_summary(tester), contains('خسارة وزن'), reason: 'the difference allowed, said where it goes');
    expect(find.byKey(const Key('split-part-share-0')), findsOneWidget);
    expect(_confirmable(tester), isFalse, reason: 'no reason yet');
    await tester.enterText(find.byKey(const Key('split-reason')), 'الزبون يريد العقد');
    await tester.pump();
    expect(_confirmable(tester), isTrue);
    await tester.tap(find.byKey(const Key('split-confirm')));
    await tester.pumpAndSettle();
    expect(api.made.single['reason'], 'الزبون يريد العقد');
    expect(api.made.single['request_key'], isNotEmpty, reason: 'pressed twice, one split');
    expect(_result?.split['entry_number'], 'JE-2026-08000');
    expect(_result?.chosen, isEmpty);
  });

  testWidgets('a refusal is the server\'s words, and nothing is made', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _part(tester, 0, 'عقد ذهب 21', '20');
    await _part(tester, 1, 'حلق ذهب 21', '6');
    expect(_summary(tester), contains('الفرق أكبر من المقبول'));
    await tester.enterText(find.byKey(const Key('split-reason')), 'سبب');
    await tester.pump();
    expect(_confirmable(tester), isFalse);
    expect(api.made, isEmpty);
  });

  testWidgets('a third part is added; two at least stay', (tester) async {
    await _open(tester, _Api());
    expect(tester.widget<IconButton>(find.byKey(const Key('split-part-remove-0'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('split-add-part')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('split-part-2')), findsOneWidget);
    expect(tester.widget<IconButton>(find.byKey(const Key('split-part-remove-0'))).onPressed, isNotNull);
  });

  testWidgets('a piece born of the split: its label printed at once, or waiting -- the seller\'s choice', (tester) async {
    for (final auto in [true, false]) {
      final api = _Api();
      await _open(tester, api);
      expect(find.byKey(const Key('split-print-mode')), findsNothing, reason: 'no piece born yet: nothing to print');
      await _part(tester, 0, 'عقد ذهب 21', '30');
      expect(find.byKey(const Key('split-print-mode')), findsNothing, reason: 'a part by weight has no label');
      await _part(tester, 1, 'اساور 21', '10');
      expect(find.byKey(const Key('split-print-mode')), findsOneWidget);
      if (!auto) {
        await tester.tap(find.text('تسجيل فقط'));
        await tester.pump();
      }
      await tester.enterText(find.byKey(const Key('split-reason')), 'بيع');
      await tester.pump();
      await tester.tap(find.byKey(const Key('split-confirm')));
      await tester.pumpAndSettle();
      expect(api.printed, [(99, auto)], reason: 'the bracelet\'s job alone; the necklace is weight');
    }
  });

  testWidgets('in the sale: which parts go into the invoice, the rest stay', (tester) async {
    final api = _Api();
    await _open(tester, api, choose: true);
    await _part(tester, 0, 'عقد ذهب 21', '30');
    await _part(tester, 1, 'اساور 21', '10');
    await tester.enterText(find.byKey(const Key('split-reason')), 'الزبون يريد العقد');
    await tester.pump();
    await tester.tap(find.byKey(const Key('split-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('JE-2026-08000'), findsOneWidget, reason: 'the entry\'s number said');
    expect(tester.widget<FilledButton>(find.byKey(const Key('split-add-chosen'))).onPressed, isNull);
    await tester.tap(find.byKey(const Key('split-choose-0')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('split-add-chosen')));
    await tester.pumpAndSettle();
    expect(_result?.chosen.map((p) => p['category_id']), [1]);
  });
}

