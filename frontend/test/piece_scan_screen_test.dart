// «جرد بالمسح» on the reader (ADR-085 ت2 ج1): a location, its kind, its scope;
// what the reader sends goes to the server in batches, each once by its key --
// a batch that met no answer sent again under the same key; every verdict and
// figure the server's; «إنهاء الجرد» waits for the server's «complete», and
// before it only an early finish with its reason; an open scan gone back to,
// its presses going on from the server's count.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/piece_scan_screen.dart';
import 'package:frontend/theme/app_theme.dart';

const _a = '4B4A00000000000000000101';
const _b = '4B4A00000000000000000102';
const _ring = '4B4A00000000000000000201';
const _attempt = '4B4A00010000000000000301';

class _Api extends ApiService {
  final started = <Map<String, dynamic>>[];
  final batches = <({String key, List<Map<String, dynamic>> events})>[];
  final finishes = <Map<String, dynamic>>[];
  int loseNext = 0;
  bool complete = false;
  List<Map<String, dynamic>> open = [];
  final settled = <int>[];

  Map<String, dynamic> _view({String status = 'open', int presses = 0}) {
    final seen = {for (final b in batches) for (final e in b.events) if (e['value'] != null) e['value'] as String};
    final reads = [
      for (final (i, v) in seen.indexed)
        if (v == _attempt)
          {
            'id': i + 1, 'value': v, 'verdict': settled.isEmpty ? 'unconfirmed' : 'found',
            'verdict_words': settled.isEmpty ? 'محاولة لم تُعتمد' : 'موجودة',
            'words': 'رقاقة من محاولة لم تُعتمد — القطعة KJ-000301 — الجيل 0001', 'unsettled': settled.isEmpty,
            'moved': null,
          }
        else
        {
          'id': i + 1,
          'value': v,
          'verdict': v == _ring ? 'other_scope' : (v == _b ? 'elsewhere' : 'found'),
          'verdict_words': v == _ring ? 'من نطاق آخر' : (v == _b ? 'في غير موقعها' : 'موجودة'),
          'words': v == _b ? 'KJ-000102 — مكانها في الدفاتر «العرض الخارجي»' : v,
          'moved': null,
        },
    ];
    return {
      'id': 7, 'safe_name': 'الذهب المعروض', 'kind_words': 'جرد إغلاق', 'scope_words': 'قسم بناجر',
      'status': status, 'presses': presses, 'expected': 2, 'found': seen.contains(_a) ? 1 : 0,
      'alerts': seen.contains(_b) ? 1 : 0, 'complete': status == 'open' ? null : !finishes.last.containsKey('early'),
      'early_reason': finishes.isEmpty ? null : finishes.last['reason'],
      'completeness': {'complete': complete, 'needs_presses': 3},
      'reads': reads,
      if (status != 'open') ...{
        'expected_counts': {'found': 1, 'missing': 1},
        'expected_pieces': [
          {'item_id': 101, 'item_code': 'KJ-000101', 'weight': 10.0, 'verdict': 'found', 'verdict_words': 'موجودة'},
          {'item_id': 103, 'item_code': 'KJ-000103', 'weight': 12.5, 'verdict': 'missing', 'verdict_words': 'ناقصة'},
        ],
      },
    };
  }

  @override
  Future<Map<String, dynamic>> pieceScanLocations() async => {
    'locations': [{'id': 30, 'name': 'الذهب المعروض', 'stock_location': 'showroom'}],
  };

  @override
  Future<Map<String, dynamic>> itemSections() async => {
    'sections': [{'id': 4, 'name': 'بناجر', 'is_active': true, 'categories': []}],
  };

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
    {'id': 28, 'name': 'بنجرة ذهب 21', 'karat': '21', 'is_scrap': false},
    {'id': 70, 'name': 'كسر 21', 'karat': '21', 'is_scrap': true},
  ];

  @override
  Future<Map<String, dynamic>> openPieceScans() async => {'scans': open};

  @override
  Future<Map<String, dynamic>> startPieceScan(Map<String, dynamic> body) async {
    started.add(body);
    return {'scan': _view()};
  }

  @override
  Future<Map<String, dynamic>> pieceScan(int scanId) async => {'scan': _view(presses: 5)};

  @override
  Future<Map<String, dynamic>> pieceScanReads(int scanId, String batchKey, List<Map<String, dynamic>> events) async {
    if (loseNext > 0) {
      loseNext--;
      throw Exception('connection lost');
    }
    if (!batches.any((b) => b.key == batchKey)) batches.add((key: batchKey, events: events));
    return {'scan': _view()};
  }

  @override
  Future<Map<String, dynamic>> settlePieceScanRead(int scanId, int readId) async {
    settled.add(readId);
    return {'scan': _view()};
  }

  @override
  Future<Map<String, dynamic>> finishPieceScan(int scanId, {bool early = false, String? reason}) async {
    finishes.add({if (early) 'early': true, if (reason != null) 'reason': reason});
    return {'scan': _view(status: 'finished')};
  }
}

int _ms = 0;

Future<void> _open(WidgetTester tester, _Api api) async {
  _ms = 0;
  tester.view.physicalSize = const Size(390, 1200);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: LightTheme.theme,
    home: PieceScanScreen(api: api, elapsed: () => _ms, sendEvery: const Duration(milliseconds: 100)),
  ));
  await tester.pumpAndSettle();
}

Future<void> _startSection(WidgetTester tester) async {
  await tester.tap(find.text('جرد إغلاق'));
  await tester.tap(find.text('قسم'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('scan-section')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('بناجر').last);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('scan-start')));
  await tester.pumpAndSettle();
}

Future<void> _read(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(const Key('scan-field')), text);
  await tester.pump(const Duration(milliseconds: 150));          // the next batch sent
  await tester.pump();
}

String _said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('a scan opened with its location, its kind and its scope', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    expect(api.started.single, {'safe_box_id': 30, 'kind': 'closing', 'section_id': 4});
    expect(_said(tester, 'scan-title'), 'الذهب المعروض — جرد إغلاق — قسم بناجر');
  });

  testWidgets('a category\'s scan offers the categories, not scrap', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.text('تصنيف'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-category')));
    await tester.pumpAndSettle();
    expect(find.text('بنجرة ذهب 21'), findsWidgets);
    expect(find.text('كسر 21'), findsNothing, reason: 'scrap is not shown: not counted by its tags');
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-start')));
    await tester.pumpAndSettle();
    expect(api.started.single, {'safe_box_id': 30, 'kind': 'check', 'category_id': 28});
  });

  testWidgets('what the reader sends goes in batches; the field emptied; the figures the server\'s', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n$_b\n$_ring\n');
    expect(api.batches.single.events.map((e) => (e['kind'], e['value'], e['press'])),
        [('read', _a, 1), ('read', _b, 1), ('read', _ring, 1)]);
    expect(api.batches.single.key, isNotEmpty);
    expect(tester.widget<TextField>(find.byKey(const Key('scan-field'))).controller!.text, isEmpty,
        reason: 'a long count never grows its field');
    expect(find.text('آخر قراءة: $_ring · الضغطة 1'), findsOneWidget, reason: 'the field emptied, what was read said');
    expect((_said(tester, 'scan-found'), _said(tester, 'scan-alerts')), ('1 من 2', '1'));
    expect(find.text('في غير موقعها'), findsOneWidget);
    expect(find.textContaining('العرض الخارجي'), findsOneWidget);
    expect(find.text('من نطاق آخر: 1 — لا تُحسب في هذا الجرد'), findsOneWidget, reason: 'not an alert');
    expect(find.text('من نطاق آخر'), findsNothing, reason: 'counted apart, never listed with the alerts');
  });

  testWidgets('a batch that met no answer is sent again under its key, once', (tester) async {
    final api = _Api()..loseNext = 1;
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(find.byKey(const Key('scan-offline')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(api.batches, hasLength(1));
    expect(find.byKey(const Key('scan-offline')), findsNothing);
    _ms = 2000;
    await _read(tester, '$_b\n');
    expect(api.batches, hasLength(2));
    expect(api.batches[1].key, isNot(api.batches[0].key));
    expect(api.batches[1].events.single['press'], 2, reason: 'a second press, two seconds later');
  });

  testWidgets('«إنهاء الجرد» waits for the server\'s complete; then the result, the missing named', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    FilledButton finish() => tester.widget<FilledButton>(find.byKey(const Key('scan-finish')));
    expect(finish().onPressed, isNull);
    expect(_said(tester, 'scan-state'), 'جارٍ المسح… مرّ بالقارئ على كل أماكن العرض');
    api.complete = true;
    _ms = 1000;
    await _read(tester, '$_a\n');
    expect(_said(tester, 'scan-state'), 'لا جديد في آخر 3 ضغطات — أنهِ إن مررت على كل أماكن العرض، أو تابع المسح');
    await tester.tap(find.byKey(const Key('scan-finish')));
    await tester.pumpAndSettle();
    expect(api.finishes.single, isEmpty, reason: 'complete: no early, no reason');
    expect(_said(tester, 'scan-result-state'), 'انتهى الجرد ومسحه مكتمل');
    expect(find.textContaining('KJ-000103'), findsOneWidget);
    expect(find.text('ناقصة'), findsOneWidget);
    expect(find.textContaining('KJ-000101'), findsNothing, reason: 'the found are counted, not listed');
  });

  testWidgets('an early finish asks its reason; with none nothing is sent', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await tester.tap(find.byKey(const Key('scan-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-early')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-early-sure')));
    await tester.pumpAndSettle();
    expect(api.finishes, isEmpty, reason: 'no reason, no finish');
    await tester.tap(find.byKey(const Key('scan-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-early')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('scan-early-reason')), 'انقطع الواي فاي');
    await tester.tap(find.byKey(const Key('scan-early-sure')));
    await tester.pumpAndSettle();
    expect(api.finishes.single, {'early': true, 'reason': 'انقطع الواي فاي'});
  });

  testWidgets('an open scan gone back to: its presses go on from the server\'s count', (tester) async {
    final api = _Api()
      ..open = [{'id': 7, 'safe_name': 'الذهب المعروض', 'kind_words': 'جرد إغلاق', 'scope_words': 'قسم بناجر',
                 'started_by': 'saleh', 'found': 3, 'expected': 9}];
    await _open(tester, api);
    expect(find.byKey(const Key('scan-open-7')), findsOneWidget);
    await tester.tap(find.text('متابعة'));
    await tester.pumpAndSettle();
    await _read(tester, '$_a\n');
    expect(api.batches.single.events.single['press'], 6, reason: 'five presses already: the next is the sixth');
  });

  testWidgets('an unsettled attempt read in the scan is settled by that reading, asked once more', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_attempt\n$_a\n$_b\n');
    expect(find.byKey(const Key('scan-read-$_b')), findsOneWidget, reason: 'an alert, shown');
    expect(find.byKey(const Key('scan-settle-$_b')), findsNothing, reason: 'an adopted tag elsewhere: nothing to settle');
    await tester.tap(find.byKey(const Key('scan-settle-$_attempt')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('رجوع'));
    await tester.pumpAndSettle();
    expect(api.settled, isEmpty, reason: 'asked once more: «رجوع» settles nothing');
    await tester.tap(find.byKey(const Key('scan-settle-$_attempt')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-settle-sure')));
    await tester.pumpAndSettle();
    expect(api.settled, [1], reason: 'the read the reader made, by its id: nothing typed');
    expect(find.byKey(const Key('scan-settle-$_attempt')), findsNothing, reason: 'settled: found, no button');
  });

  testWidgets('a dialog over the scan: the reader\'s panel does not take the focus back from it', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    FocusNode panel() => tester
        .widget<EditableText>(find.descendant(of: find.byKey(const Key('scan-field')), matching: find.byType(EditableText)))
        .focusNode;
    await tester.tap(find.byKey(const Key('scan-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-early')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(panel().hasFocus, isFalse, reason: 'the reason\'s dialog is over it: its field is the dialog\'s');
    await tester.tap(find.text('رجوع'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(panel().hasFocus, isTrue, reason: 'the dialog gone: the panel hears the reader again');
  });
}
