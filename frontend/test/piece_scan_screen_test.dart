// «جرد بالمسح» on the reader (ADR-085 ت2 ج1): a location, its kind, its scope;
// what the reader sends goes to the server in batches, each once by its key --
// a batch that met no answer sent again under the same key; every verdict and
// figure the server's; «إنهاء الجرد» waits for the server's «complete», and
// before it only an early finish with its reason; an open scan gone back to,
// its presses going on from the server's count.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/bidi.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/piece_scan_screen.dart';
import 'package:frontend/screens/safe_transfer_screen.dart';
import 'package:frontend/widgets/piece_scan_result.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/scan_feedback.dart';

const _a = '4B4A00000000000000000101';
const _b = '4B4A00000000000000000102';
const _ring = '4B4A00000000000000000201';
const _attempt = '4B4A00010000000000000301';

class _Api extends ApiService {
  final started = <Map<String, dynamic>>[];
  final batches = <({String key, List<Map<String, dynamic>> events})>[];
  final finishes = <Map<String, dynamic>>[];
  int loseNext = 0;
  /// The server's answers to the next batches, before any is taken: a 502, a 500, a 401, a refusal.
  final refusals = <ApiException>[];
  /// Each batch's key as it was sent, taken or not.
  final tried = <String>[];
  /// What each batch said the screen holds: the last read's id.
  final sinces = <int?>[];
  bool complete = false;
  bool allFound = false;
  int quiet = 0;
  List<Map<String, dynamic>> open = [];
  final settled = <int>[];
  /// The scan's expected pieces, as the server says them when the scan is read whole.
  /// The place's last finished count, as the server says it with the places -- none: never counted.
  Map<String, dynamic>? lastScan = {
    'id': 3, 'kind_words': 'جرد إغلاق', 'finished_at': '2026-11-26T21:05:00', 'finished_by_name': 'سارة',
    'found': 120, 'expected': 122, 'complete': true, 'missing': 2,
  };
  List<Map<String, dynamic>> expectedList = [
    {'item_id': 101, 'item_code': 'KJ-000101', 'weight': 10.0, 'piece_name': 'بنجرة الشمس'},
    {'item_id': 103, 'item_code': 'KJ-000103', 'weight': 12.5, 'piece_name': 'خاتم لؤلؤ'},
  ];

  Map<String, dynamic> _view({String status = 'open', int presses = 0, int? since}) {
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
          'item_id': v == _a ? 101 : (v == _b ? 102 : null),
          if (v == _b) 'item_code': 'KJ-000102',
          if (v == _b && status != 'open') 'place_now': {'id': 31, 'name': 'العرض الخارجي'},
          'weight': v == _a ? 10.0 : (v == _b ? 11.0 : null),
          'piece_name': v == _a ? 'بنجرة الشمس' : (v == _b ? 'خاتم لؤلؤ' : null),
          'verdict_words': v == _ring ? 'من نطاق آخر' : (v == _b ? 'في غير موقعها' : 'موجودة'),
          'words': v == _b
              ? 'KJ-000102 — مكانها في الدفاتر «العرض الخارجي»'
              : (v == _ring ? 'KJ-000201 — ليست من نطاق هذا الجرد' : v),
          'moved': null,
        },
    ];
    final counts = <String, int>{};
    for (final r in reads) {
      counts['${r['verdict']}'] = (counts['${r['verdict']}'] ?? 0) + 1;
    }
    // as the server answers a batch: every alert, and the reads after the last the screen holds
    final said = since == null
        ? reads
        : [for (final r in reads) if ((r['id'] as int) > since || !{'found', 'other_scope'}.contains(r['verdict'])) r];
    return {
      if (since != null) 'reads_since': since,
      'counts': counts,
      'id': 7, 'safe_box_id': 30, 'kind': 'closing', 'section_id': 4, 'category_id': null,
      'safe_name': 'الذهب المعروض', 'kind_words': 'جرد إغلاق', 'scope_words': 'قسم بناجر',
      'status': status, 'presses': presses, 'expected': 2, 'found': seen.contains(_a) ? 1 : 0,
      'expected_grams': 22.5, 'found_grams': seen.contains(_a) ? 10.0 : 0.0,
      'by_karat': [
        {'karat': '18', 'expected_grams': 12.5, 'found_grams': 0.0, 'not_found_grams': 12.5},
        {'karat': '21', 'expected_grams': 10.0, 'found_grams': seen.contains(_a) ? 10.0 : 0.0,
         'not_found_grams': seen.contains(_a) ? 0.0 : 10.0},
      ],
      'alerts': seen.contains(_b) ? 1 : 0, 'complete': status == 'open' ? null : !finishes.last.containsKey('early'),
      'early_reason': finishes.isEmpty ? null : finishes.last['reason'],
      'completeness': {'complete': complete, 'all_found': allFound, 'needs_presses': 3, 'quiet_presses': quiet},
      'reads': said,
      if (status == 'open' && since == null) 'expected_pieces': expectedList,
      if (status != 'open') ...{
        'expected_counts': {'found': 1, 'missing': 1},
        'expected_pieces': [
          {'item_id': 101, 'item_code': 'KJ-000101', 'weight': 10.0, 'verdict': 'found', 'verdict_words': 'موجودة',
           'piece_name': 'بنجرة الشمس'},
          {'item_id': 103, 'item_code': 'KJ-000103', 'weight': 12.5, 'verdict': 'missing', 'verdict_words': 'ناقصة',
           'piece_name': 'خاتم لؤلؤ'},
        ],
      },
    };
  }

  @override
  Future<Map<String, dynamic>> pieceScanLocations() async => {
    'locations': [{'id': 30, 'name': 'الذهب المعروض', 'stock_location': 'showroom', 'last_scan': lastScan}],
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
  Future<Map<String, dynamic>> pieceScanReads(int scanId, String batchKey, List<Map<String, dynamic>> events,
      {int? since}) async {
    tried.add(batchKey);
    sinces.add(since);
    if (refusals.isNotEmpty) throw refusals.removeAt(0);
    if (events.length > 2000) {                       // as the server refuses it (EVENTS_A_BATCH), for good
      throw const ApiException(statusCode: 400, code: 'scan_events_invalid', message: 'الدفعة قائمة من 2000 قراءة على الأكثر');
    }
    if (loseNext > 0) {
      loseNext--;
      throw Exception('connection lost');
    }
    if (!batches.any((b) => b.key == batchKey)) batches.add((key: batchKey, events: events));
    return {'scan': _view(since: since)};
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
    expect(find.text(isolateLatin('آخر قراءة: KJ-000201 — ليست من نطاق هذا الجرد · الضغطة 1')), findsOneWidget,
        reason: 'the field emptied, what was read said -- in the server\'s words, not the tag\'s raw value');
    expect((_said(tester, 'scan-found'), _said(tester, 'scan-found-of'), _said(tester, 'scan-alerts')),
        (isolateLatin('1'), isolateLatin('من 2'), isolateLatin('1')),
        reason: 'the count large, its total small under it: one line each on a reader (the shots, 27 Nov 2026)');
    expect(find.text('في غير موقعها'), findsOneWidget);
    expect(find.textContaining('العرض الخارجي'), findsOneWidget);
    expect(find.text('من نطاق آخر: 1 — خارج حساب هذا الجرد'), findsOneWidget, reason: 'not an alert');
    expect(find.text('من نطاق آخر'), findsNothing, reason: 'counted apart, never listed with the alerts');
  });

  // The owner, 22 Nov 2026 (the screens by a designer's eye): «إنهاء الجرد» greyed with no reason said, and
  // «1 من 2» a bare figure. Under the button, what is left before it can be pressed; under the figure, a bar.
  testWidgets('while scanning: how many quiet presses are left before finishing, and how far the count is', (tester) async {
    final api = _Api()..quiet = 1;
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(_said(tester, 'scan-finish-hint'), 'يُتاح الإنهاء بعد 3 ضغطات بلا قراءة جديدة — بقي ضغطتان',
        reason: 'why the button waits, and how long');
    final bar = tester.widget<LinearProgressIndicator>(find.byKey(const Key('scan-progress')));
    expect(bar.value, 0.5, reason: 'one of two found');
    api
      ..quiet = 3
      ..complete = true;
    await _read(tester, '$_a\n');
    expect(find.byKey(const Key('scan-finish-hint')), findsNothing, reason: 'complete: the button speaks for itself');
  });

  // The owner's rehearsal, 23 Nov 2026: «عرض لبيانات مثل الوزن الممسوح».
  testWidgets('the grams found against the grams expected, and each piece its weight', (tester) async {
    await _open(tester, _Api());
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(_said(tester, 'scan-grams'), isolateLatin('الوزن الموجود: 10.00 من 22.50 جم'),
        reason: 'a line, not a tile: «756.65 / 974.00 جم» broke on three lines in a tile (the shots, 27 Nov 2026)');
    expect(find.byType(ScanFigure), findsNWidgets(2), reason: 'two tiles while scanning: found, and the alerts');
    await tester.tap(find.byKey(const Key('scan-found-list')));
    await tester.pumpAndSettle();
    final line = tester.widget<Text>(find.descendant(of: find.byKey(const Key('scan-read-$_a')),
        matching: find.textContaining('بنجرة الشمس'))).data!;
    expect(line.contains('10.00'), isTrue, reason: line);
  });

  // The owner's rehearsal, 23 Nov 2026: «تظهر جميع القطع من أول مسحة وزر إنهاء الجرد لا زال غير مفعّل».
  testWidgets('every piece found at the first press: the finish is offered at once, and said why', (tester) async {
    final api = _Api()
      ..complete = true
      ..allFound = true;
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(_said(tester, 'scan-state'), 'وُجدت كل القطع المتوقعة — يمكنك إنهاء الجرد');
    expect(find.byKey(const Key('scan-finish-hint')), findsNothing);
    expect(tester.widget<ButtonStyleButton>(find.byKey(const Key('scan-finish'))).onPressed, isNotNull);
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

  // What follows an alert (the owner, 27 Nov 2026: «اكمل»): a piece here that the books hold elsewhere
  // -- the transfer voucher that corrects it, its source, target and pieces filled in, to be looked at
  // and sent by the employee; the count itself moves nothing. Another check of the same place and scope.
  testWidgets('after the finish: a voucher from where the books hold the pieces, and another check', (tester) async {
    final api = _Api()..complete = true;
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n$_b\n');
    await tester.tap(find.byKey(const Key('scan-finish')));
    await tester.pumpAndSettle();
    expect(find.text(isolateLatin('سند نقل من «العرض الخارجي» إلى هنا (قطعة واحدة)')), findsOneWidget);
    // the result's alerts as the scanning screen's -- what it is and its weight -- and the voucher right
    // under the pieces it corrects, not after every list (the shots, 27 Nov 2026)
    expect(find.descendant(of: find.byKey(Key('scan-read-$_b')), matching: find.textContaining(isolateLatin('خاتم لؤلؤ 11.00 جم'))),
        findsOneWidget);
    final alert = tester.getBottomLeft(find.byKey(Key('scan-read-$_b'))).dy;
    final voucher = tester.getTopLeft(find.byKey(const Key('scan-transfer-31'))).dy;
    expect(voucher - alert, lessThan(40), reason: 'right under its alert');
    await tester.tap(find.byKey(const Key('scan-check-again')));
    await tester.pumpAndSettle();
    expect(api.started.last, {'safe_box_id': 30, 'kind': 'check', 'section_id': 4},
        reason: 'the same place and scope, a check');
  });

  testWidgets('the voucher opens on its source, the place counted and its pieces', (tester) async {
    final api = _Api()..complete = true;
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n$_b\n');
    await tester.tap(find.byKey(const Key('scan-finish')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('scan-transfer-31')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    final voucher = tester.widget<SafeTransferScreen>(find.byType(SafeTransferScreen));
    expect((voucher.initialMode, voucher.initialFromSafeId, voucher.initialToSafeId), ('gold', 31, 30));
    expect(voucher.initialPieces, ['KJ-000102']);
    expect(voucher.initialNotes, contains('جرد بالمسح'));
  });

  // The start says when the place was last counted, and what it found (the owner, 27 Nov 2026: «اكمل»).
  testWidgets('the start says the place\'s last count, or that it was never counted', (tester) async {
    final api = _Api();
    await _open(tester, api);
    final said = _said(tester, 'scan-last');
    for (final part in ['آخر جرد: جرد إغلاق', 'سارة', 'موجودة 120 من 122', 'ناقصة 2']) {
      expect(said, contains(isolateLatin(part)));
    }
  });

  testWidgets('a place never counted is said so on the start', (tester) async {
    await _open(tester, _Api()..lastScan = null);
    expect(_said(tester, 'scan-last'), 'لم يُجرد هذا الموقع بالمسح بعد');
  });

  // The grams by karat, the server's figures: while scanning when more than one karat, and at the end.
  testWidgets('the grams by karat: found of expected, and what is not found yet, then at the end', (tester) async {
    final api = _Api()..complete = true;
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(_said(tester, 'scan-karat-18'), isolateLatin('18K · موجود 0.00 من 12.50 جم · بقي 12.50 جم'));
    expect(_said(tester, 'scan-karat-21'), isolateLatin('21K · موجود 10.00 من 10.00 جم'));
    await tester.tap(find.byKey(const Key('scan-finish')));
    await tester.pumpAndSettle();
    expect(_said(tester, 'scan-karat-18'), isolateLatin('18K · موجود 0.00 من 12.50 جم · لم يوجد 12.50 جم'));
  });

  // The system's tones on a count (the owner, 27 Nov 2026: «اكمل»; the reader's own beep is off): the
  // eyes on the vitrine, not on the screen -- a tone when a read needs looking at, once for each, and
  // one when every piece expected is found; a found read says nothing (hundreds a second).
  testWidgets('a read to look at sounds once; a found one says nothing; every piece found sounds', (tester) async {
    final said = <bool>[];
    final before = ScanFeedback.say;
    ScanFeedback.say = said.add;
    addTearDown(() => ScanFeedback.say = before);
    var completes = 0;
    final beforeComplete = ScanFeedback.sayComplete;
    ScanFeedback.sayComplete = () => completes++;
    addTearDown(() => ScanFeedback.sayComplete = beforeComplete);
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(said, isEmpty, reason: 'found: no tone');
    _ms = 1000;
    await _read(tester, '$_b\n');
    expect(said, [false], reason: 'in another place: looked at');
    _ms = 2000;
    await _read(tester, '$_b\n$_a\n');
    expect(said, [false], reason: 'the same alert again: not again');
    api.allFound = true;
    _ms = 3000;
    await _read(tester, '$_a\n');
    expect(said, [false]);
    expect(completes, 1, reason: 'every piece expected found: its own tone, once');
    _ms = 4000;
    await _read(tester, '$_a\n');
    expect(said, [false]);
    expect(completes, 1);
  });

  // The owner's trial on the reader (27 Nov 2026): «لا يسمع الا صوت الخطأ ولا يسمع صوت اكتمال القطع» --
  // every piece and two alerts were read in one press, one answer: both tones at the same instant, the
  // alert's two low notes and buzz over the found one's short beep. The completion now its own tone,
  // after the alert's when both come together.
  testWidgets('an alert and every piece found in one answer: the alert, then the completion after it', (tester) async {
    final said = <bool>[];
    final before = ScanFeedback.say;
    ScanFeedback.say = said.add;
    addTearDown(() => ScanFeedback.say = before);
    var completes = 0;
    final beforeComplete = ScanFeedback.sayComplete;
    ScanFeedback.sayComplete = () => completes++;
    addTearDown(() => ScanFeedback.sayComplete = beforeComplete);
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    api.allFound = true;                              // the answer to this press: every piece found
    await _read(tester, '$_a\n$_b\n');
    expect(said, [false]);
    expect(completes, 0, reason: 'the alert first, alone');
    await tester.pump(const Duration(milliseconds: 700));
    expect(said, [false]);
    expect(completes, 1, reason: 'then the completion, heard');
  });

  // The third tone (the owner, 27 Nov 2026: «في حال كان هناك نقص هل يجب ان يكون له صوت خاص» --
  // «ابنها»): the scan complete -- no new tag in the last presses -- and pieces expected still not read:
  // two falling notes, once as it becomes so; again only after a new read and another quiet. Not at
  // the finish: the screen is before the eyes then.
  testWidgets('complete with pieces still unread sounds once; read on and quiet again, once more', (tester) async {
    final said = <bool>[];
    final before = ScanFeedback.say;
    ScanFeedback.say = said.add;
    addTearDown(() => ScanFeedback.say = before);
    var stalls = 0, completes = 0;
    final beforeStall = ScanFeedback.sayStalled, beforeComplete = ScanFeedback.sayComplete;
    ScanFeedback.sayStalled = () => stalls++;
    ScanFeedback.sayComplete = () => completes++;
    addTearDown(() {
      ScanFeedback.sayStalled = beforeStall;
      ScanFeedback.sayComplete = beforeComplete;
    });
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n');
    expect(stalls, 0, reason: 'still reading');
    api.complete = true;
    _ms = 1000;
    await _read(tester, '$_a\n');
    expect(stalls, 1, reason: 'quiet, and a piece expected not read');
    _ms = 2000;
    await _read(tester, '$_a\n');
    expect(stalls, 1, reason: 'still so: not again');
    api.complete = false;
    _ms = 3000;
    await _read(tester, '$_a\n');
    api.complete = true;
    _ms = 4000;
    await _read(tester, '$_a\n');
    expect(stalls, 2, reason: 'read on, then quiet again');
    api.allFound = true;
    _ms = 5000;
    await _read(tester, '$_a\n');
    expect((stalls, completes), (2, 1), reason: 'every piece found: the completion, not the stall');
    expect(said, isEmpty);
  });

  testWidgets('an alert and the stall in one answer: the alert, then the stall after it', (tester) async {
    final said = <bool>[];
    final before = ScanFeedback.say;
    ScanFeedback.say = said.add;
    addTearDown(() => ScanFeedback.say = before);
    var stalls = 0;
    final beforeStall = ScanFeedback.sayStalled;
    ScanFeedback.sayStalled = () => stalls++;
    addTearDown(() => ScanFeedback.sayStalled = beforeStall);
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    api.complete = true;
    await _read(tester, '$_a\n$_b\n');
    expect(said, [false]);
    expect(stalls, 0, reason: 'the alert first, alone');
    await tester.pump(const Duration(milliseconds: 700));
    expect(stalls, 1);
  });

  // «ما بقي» as the reader goes (the owner, 27 Nov 2026: «اكمل»): the expected pieces the server said
  // when the scan opened, the found taken away -- each piece while few, by what it is when many.
  testWidgets('what is left: the expected not yet found, each said, going as they are read', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await tester.tap(find.byKey(const Key('scan-remaining')));
    await tester.pumpAndSettle();
    expect(find.text('ما بقي (2)'), findsOneWidget);
    expect(find.byKey(const Key('scan-left-101')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('scan-left-103')), matching: find.textContaining('خاتم لؤلؤ')),
        findsOneWidget, reason: 'what it is');
    await _read(tester, '$_a\n');
    await tester.pumpAndSettle();
    expect(find.text('ما بقي (1)'), findsOneWidget);
    expect(find.byKey(const Key('scan-left-101')), findsNothing, reason: 'read: gone from what is left');
    expect(find.byKey(const Key('scan-left-103')), findsOneWidget);
  });

  testWidgets('what is left of many is said by what it is: how many, and their grams', (tester) async {
    final api = _Api()
      ..expectedList = [
        for (var i = 0; i < 40; i++) {'item_id': 1000 + i, 'item_code': 'KJ-00${1000 + i}', 'weight': 2.5,
                                       'piece_name': 'بنجرة الشمس'},
        for (var i = 0; i < 5; i++) {'item_id': 2000 + i, 'item_code': 'KJ-00${2000 + i}', 'weight': 1.0,
                                      'piece_name': 'خاتم لؤلؤ'},
      ];
    await _open(tester, api);
    await _startSection(tester);
    await tester.tap(find.byKey(const Key('scan-remaining')));
    await tester.pumpAndSettle();
    expect(find.text('ما بقي (45)'), findsOneWidget);
    expect(find.byKey(const Key('scan-left-1000')), findsNothing, reason: 'not 45 lines');
    expect(find.text(isolateLatin('بنجرة الشمس: 40 قطعة · 100.00 جم')), findsOneWidget);
    expect(find.text(isolateLatin('خاتم لؤلؤ: 5 قطع · 5.00 جم')), findsOneWidget);
    expect(tester.getTopLeft(find.textContaining('بنجرة الشمس:')).dy,
        lessThan(tester.getTopLeft(find.textContaining('خاتم لؤلؤ:')).dy), reason: 'the most first');
  });

  // More than 500 pieces a location (the owner, 27 Nov 2026): each batch says the last read the screen
  // holds, and its answer carries every alert and the reads after it -- the found held from before.
  testWidgets('a batch says the last read held; the found are held across answers that bring the new only',
      (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    await _read(tester, '$_a\n$_ring\n');
    expect(api.sinces.single, 0, reason: 'none held yet');
    _ms = 2000;
    await _read(tester, '$_a\n$_b\n');
    expect(api.sinces.last, 2, reason: 'the last read held: the second');
    await tester.tap(find.byKey(const Key('scan-found-list')));
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byKey(const Key('scan-found-list')), matching: find.byKey(const Key('scan-read-$_a'))),
        findsOneWidget, reason: 'held from the first answer, not sent again');
    expect(find.text('الموجودة (1)'), findsOneWidget);
    expect(find.text('في غير موقعها'), findsOneWidget, reason: 'the alert, in the answer that brought it');
    expect(find.text('من نطاق آخر: 1 — خارج حساب هذا الجرد'), findsOneWidget, reason: 'the server\'s count');
  });

  // The server takes a batch of 2000 reads at most (EVENTS_A_BATCH) and refuses a longer one for good:
  // what the reader sent while the server was out of reach -- a vitrine of more than 1000 pieces (the
  // owner, 27 Nov 2026) -- goes in batches the server takes, none refused and dropped.
  testWidgets('what waited while the server was out of reach goes in batches the server takes', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    api.loseNext = 3;
    final many = [for (var i = 0; i < 2500; i++) '4B4A0000000000000${(500000 + i).toString().padLeft(7, '0')}'];
    await _read(tester, '${many.join('\n')}\n');
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(api.batches.every((b) => b.events.length <= PieceScanScreen.batchMost), isTrue,
        reason: 'each within what the server takes');
    expect(PieceScanScreen.batchMost, lessThanOrEqualTo(2000));
    expect({for (final b in api.batches) for (final e in b.events) e['value']}, many.toSet(), reason: 'none lost');
  });

  // A batch the server did not take for a passing reason -- restarted (502), failed inside (500), the
  // session ended (401) -- is kept and sent again under its key: its reads are not lost, a piece read
  // only in it is not said missing at the finish. The key makes a second sending harmless.
  for (final (status, said) in [
    (502, 'لا يصل الخادم: قراءات لم تُرسل بعد، وهي في هذه الصفحة وحدها — لا تغلقها ولا تُعِد تحميلها حتى تُرسل'),
    (500, 'لا يصل الخادم: قراءات لم تُرسل بعد، وهي في هذه الصفحة وحدها — لا تغلقها ولا تُعِد تحميلها حتى تُرسل'),
    (401, 'انتهت الجلسة: سجّل الدخول من جديد في نافذة أخرى — القراءات في هذه الصفحة تُرسل بعده، فلا تغلقها'),
  ]) {
    testWidgets('a batch the server answered $status is kept, said, and sent again under its key', (tester) async {
      final api = _Api();
      await _open(tester, api);
      await _startSection(tester);
      api.refusals.addAll([
        ApiException(statusCode: status, code: 'http_error', message: 'x'),
        ApiException(statusCode: status, code: 'http_error', message: 'x'),
      ]);
      await _read(tester, '$_a\n');
      expect(api.batches, isEmpty);
      expect(_said(tester, 'scan-offline'), said, reason: 'where its reads are, truly: this page alone');
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(api.batches.single.events.single['value'], _a, reason: 'sent again, then taken');
      expect(api.tried, hasLength(3), reason: 'refused twice, taken the third time');
      expect(api.tried.toSet(), {api.batches.single.key}, reason: 'every sending under its one key');
      expect(find.byKey(const Key('scan-offline')), findsNothing);
    });
  }

  testWidgets('a batch refused for good -- the scan closed elsewhere -- is dropped, said, not sent again',
      (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _startSection(tester);
    api.refusals.add(const ApiException(
        statusCode: 409, code: 'scan_not_open', message: 'جلسة الجرد منتهية أو متروكة: لا تُقرأ فيها رقاقات'));
    await _read(tester, '$_a\n');
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(api.tried, hasLength(1), reason: 'the same answer would come again');
    expect(find.text('جلسة الجرد منتهية أو متروكة: لا تُقرأ فيها رقاقات'), findsOneWidget);
  });

  testWidgets('the finish waits for the reads not yet sent: none judged without them', (tester) async {
    final api = _Api()..complete = true;
    await _open(tester, api);
    await _startSection(tester);
    api.loseNext = 99;
    await _read(tester, '$_a\n');
    await tester.tap(find.byKey(const Key('scan-finish')));
    await tester.pumpAndSettle();
    expect(api.finishes, isEmpty, reason: 'a piece in an unsent batch would be said missing');
    expect(find.text('قراءات لم تصل الخادم بعد: لا يُنهى الجرد حتى تُرسل'), findsOneWidget);
    api.loseNext = 0;
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    expect(api.batches, hasLength(1));
    await tester.tap(find.byKey(const Key('scan-finish')));
    await tester.pumpAndSettle();
    expect(api.finishes, hasLength(1), reason: 'sent: then finished');
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
    expect(find.descendant(of: find.byKey(const Key('scan-piece-103')), matching: find.textContaining('خاتم لؤلؤ')),
        findsOneWidget, reason: 'the missing said by what it is');
    expect(find.descendant(of: find.byKey(const Key('scan-piece-103')), matching: find.text('ناقصة')), findsOneWidget);
    expect(_said(tester, 'scan-count-missing'), isolateLatin('1'), reason: 'and counted in its tile');
    expect(_said(tester, 'scan-count-found-of'), isolateLatin('من 2'), reason: 'found of how many, as while scanning');
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
