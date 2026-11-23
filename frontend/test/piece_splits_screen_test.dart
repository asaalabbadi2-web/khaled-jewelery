// «سجلّ التفكيك» (ADR-099; the owner, 23 Nov 2026): who, when, why, into what.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/piece_splits_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Api extends ApiService {
  _Api(this.splits);
  final List<Map<String, dynamic>> splits;

  @override
  Future<List<Map<String, dynamic>>> pieceSplits() async => splits;
}

Future<void> _open(WidgetTester tester, _Api api) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceSplitsScreen(api: api)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('each split: the piece, who and when, why, its parts, its difference', (tester) async {
    await _open(tester, _Api([
      {
        'id': 1, 'item_code': 'KJ-000011', 'category_name': 'طقم ذهب 21', 'weight': 40.0, 'reason': 'الزبون يريد العقد',
        'split_by': 'mubarak', 'split_by_name': 'مبارك المصعبي', 'split_at': '2026-11-23T12:05:00',
        'entry_number': 'JE-2026-07950', 'difference': -0.03,
        'parts': [
          {'category_name': 'عقد ذهب 21', 'weight': 20.0, 'wage': 600.0, 'item_code': null},
          {'category_name': 'بنجرة ذهب 21', 'weight': 19.97, 'wage': 600.0, 'item_code': 'KJ-000015'},
        ],
      },
    ]));
    expect(find.textContaining('KJ-000011'), findsWidgets);
    expect(find.textContaining('مبارك المصعبي'), findsOneWidget);
    expect(find.text('السبب: الزبون يريد العقد'), findsOneWidget);
    expect(find.textContaining('وزنًا في تصنيفه'), findsOneWidget);
    expect(find.textContaining('KJ-000015'), findsOneWidget);
    expect(find.byKey(const ValueKey('split-difference-1')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'a phone\'s width: nothing cut');
  });

  testWidgets('none yet: says where a split is made', (tester) async {
    await _open(tester, _Api(const []));
    expect(find.text('لم تُفكَّك قطعة بعد'), findsOneWidget);
  });
}
