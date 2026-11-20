// ADR-087 R3.4: «محطة ترميز القطع». The list is the server's lines left to
// code; a line opened, each piece typed and sent with its attempt's key --
// the server's number shown to write on its tag, the counter moved, the
// wage «بانتظار الفاتورة» until the invoice. Refused, the server's words are
// said and the next attempt is a new key; a lost answer keeps the key. A
// batch of the stock on hand takes no wage: each of its pieces is sent with
// its own, per gram or whole (ADR-096 §4; the owner, 19 Nov 2026).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/screens/piece_station_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/piece_label_actions.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _batch({int pieces = 0, double coded = 0, bool fromPool = false}) => {
  'kind': 'stock', 'line_id': null, 'coding_id': 5, 'invoice_number': 'ترميز مخزون #5',
  'safe_name': 'المعرض', 'category_name': 'بنجرة ذهب 21', 'karat': 21, 'weight': 50.0,
  'wage_per_gram': null, 'wage_by_piece': !fromPool, 'wage_from_pool': fromPool,
  'pool_wage_per_gram': fromPool ? 20.0 : null, 'pieces': pieces, 'pieces_weight': coded,
  'rest': double.parse((50.0 - coded).toStringAsFixed(3)),
};

Map<String, dynamic> _line({int pieces = 0, double coded = 0}) => {
  'line_id': 7, 'invoice_id': 900, 'invoice_number': 'PUR-2027-00001', 'stage': 'received',
  'supplier_name': 'مفيد الحبيشي', 'category_id': 28, 'category_name': 'بنجرة ذهب 21',
  'karat': 21, 'weight': 30.0, 'pieces': pieces, 'pieces_weight': coded,
  'rest': double.parse((30.0 - coded).toStringAsFixed(3)),
};

class _Api extends ApiService {
  final sent = <Map<String, dynamic>>[];
  final opened = <Map<String, dynamic>>[];

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [
    SafeBoxModel.fromJson({'id': 3, 'account_id': 30, 'name': 'المعرض', 'safe_type': 'gold', 'stock_location': 'showroom'}),
    SafeBoxModel.fromJson({'id': 4, 'account_id': 40, 'name': 'وديعة المكتب', 'safe_type': 'gold', 'stock_location': 'deposit'}),
  ];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
    {'id': 28, 'name': 'بنجرة ذهب 21', 'karat': '21', 'is_active': true, 'tracking': 'piece'},
    {'id': 30, 'name': 'خواتم 21', 'karat': '21', 'is_active': true},
  ];

  /// From 2027's opening: the pool's average, not a wage written (ADR-096 ت3).
  bool fromPool = false;

  @override
  Future<Map<String, dynamic>> stockCodingRoom(int safeBoxId, int categoryId) async =>
      {'free': 120.0, 'reserved': 0.0, 'room': 120.0, 'karat': 21, 'wage_from_pool': fromPool,
       'pool_wage_per_gram': fromPool ? 20.0 : null};

  @override
  Future<Map<String, dynamic>> openStockCoding(Map<String, dynamic> body) async {
    opened.add(body);
    return {'line': _batch(fromPool: fromPool), 'pieces': []};
  }

  ApiException? refuseNext;
  bool loseNext = false;
  int _n = 0;

  // Its label (ADR-097): the printer, the jobs, each request recorded.
  bool printerReady = true;
  String printOutcome = 'completed';
  final printed = <Map<String, dynamic>>[];
  final runs = <int>[];
  final resolved = <Map<String, dynamic>>[];
  Map<String, dynamic> counts = {'pending': 0, 'failed': 0, 'needs_attention': 0};
  List<Map<String, dynamic>> openJobs = [];
  int _job = 0;

  Map<String, dynamic> _jobOf(int pieceId, String status, {String kind = 'first', int generation = 1}) => {
    'id': ++_job, 'item_id': pieceId, 'item_code': 'KJ-00012${pieceId - 100}', 'kind': kind, 'status': status,
    'last_attempt': status == 'pending' ? null : {
      'id': 500 + _job, 'generation': generation, 'printed': status == 'completed',
      'written': status == 'completed', 'verified': status == 'completed',
      'message': status == 'failed'
          ? 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'
          : status == 'needs_attention'
              ? 'انقطع الاتصال بالطابعة أثناء الطباعة'
              : null,
    },
  };

  @override
  Future<Map<String, dynamic>> labelPreview(int pieceId) async => {
    'faces': {'code': 'KJ-000121', 'number': 'KJ-000121', 'facts': '21K · 14.37g', 'name': 'بنجرة ذهب 21',
              'marks': null},
  };

  @override
  Future<Map<String, dynamic>> labelPrinters() async => {
    'printers': [{'id': 1, 'name': 'طابعة المعرض', 'is_active': true}],
  };

  int statusAsked = 0;

  @override
  Future<Map<String, dynamic>> labelPrinterStatus(int printerId) async {
    statusAsked++;
    return {
    'status': printerReady
        ? {'ready': true, 'stops': [], 'message': null}
        : {'ready': false, 'stops': ['paper_out'], 'message': 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'},
    };
  }

  @override
  Future<Map<String, dynamic>> printJobsOpen() async => {'jobs': openJobs, 'counts': counts};

  @override
  Future<Map<String, dynamic>> printPieceLabel(int pieceId, Map<String, dynamic> body) async {
    printed.add({...body, 'piece_id': pieceId});
    if (busyFor > 0) {
      busyFor--;
      return {'job': _jobOf(pieceId, 'pending'), 'printer': {'ready': true, 'busy': true, 'message': 'الطابعة مشغولة ببطاقة أخرى: تُطبع بعدها'}};
    }
    if (printOutcome == 'not_ready') {
      // asked first, not ready: the job waits, nothing spent (ADR-097, ط6)
      return {
        'job': _jobOf(pieceId, 'pending', kind: '${body['kind']}'),
        'printer': {'ready': false, 'stops': ['unreachable'],
                    'message': 'الطابعة لا تردّ: تأكد أنها مشغّلة وعلى الشبكة ثم أعد المحاولة'},
      };
    }
    final status = body['run'] == false ? 'pending' : printOutcome;
    return {'job': _jobOf(pieceId, status, kind: '${body['kind']}', generation: printed.length)};
  }

  /// Answers «busy» this many times first (another label printing).
  int busyFor = 0;

  @override
  Future<Map<String, dynamic>> runPrintJob(int jobId) async {
    runs.add(jobId);
    if (busyFor > 0) {
      busyFor--;
      return {'job': _jobOf(101, 'pending'), 'printer': {'ready': true, 'busy': true, 'message': 'مشغولة'}};
    }
    return {'job': _jobOf(101, 'completed', generation: 2)};
  }

  @override
  Future<Map<String, dynamic>> resolvePrintAttempt(int attemptId, Map<String, dynamic> body) async {
    resolved.add({...body, 'attempt_id': attemptId});
    return {'job': _jobOf(101, body['no_label'] == true ? 'failed' : 'completed')};
  }

  @override
  Future<List<Map<String, dynamic>>> piecesPending() async => [_line()];

  @override
  Future<Map<String, dynamic>> pieceLine(int lineId) async => {'line': _line(), 'pieces': []};

  @override
  Future<Map<String, dynamic>> registerPiece(Map<String, dynamic> body) async {
    sent.add(body);
    if (refuseNext != null) {
      final e = refuseNext!;
      refuseNext = null;
      throw e;
    }
    if (loseNext) {
      loseNext = false;
      throw Exception('connection lost');
    }
    _n++;
    final w = (body['weight'] as num).toDouble();
    return {
      'piece': {'id': 100 + _n, 'item_code': 'KJ-00012$_n', 'weight': w, 'stones_weight': 0,
                'wage': null, 'wage_known': false},
      'line': body.containsKey('coding_id')
          ? _batch(pieces: _n, coded: w, fromPool: fromPool)
          : _line(pieces: _n, coded: w),
    };
  }
}

Future<void> _open(WidgetTester tester, _Api api, {Size size = const Size(1400, 1800)}) async {
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('station-line-7')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a piece typed is sent with its key; its number shown, the counter moved', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.textContaining('الباقي 30.00 جم'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['line_id'], 7);
    expect(api.sent.single['weight'], 14.37);
    expect(api.sent.single['request_key'], isNotEmpty);
    expect(find.descendant(of: find.byKey(const Key('station-last')), matching: find.text('KJ-000121')),
        findsOneWidget);
    expect(find.textContaining('الباقي 15.63 جم'), findsOneWidget);
    expect(find.text('بانتظار الفاتورة'), findsOneWidget);
    expect(find.byKey(const Key('piece-wage')), findsNothing, reason: 'a receipt\'s piece takes its invoice\'s wage');
    expect(api.sent.single.containsKey('wage'), isFalse);
  });

  testWidgets('refused, the words said and the next attempt a new key', (tester) async {
    final api = _Api()
      ..refuseNext = const ApiException(statusCode: 400, code: 'piece_heavier_than_rest',
          message: 'القطعة (31.00 جم) أثقل من باقي السطر (30.00 جم)');
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '31');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(find.textContaining('أثقل من باقي السطر'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], isNot(api.sent[0]['request_key']));
  });

  testWidgets('a lost answer keeps the key: sent again, the same piece', (tester) async {
    final api = _Api()..loseNext = true;
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('piece-weight')), '14.37');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], api.sent[0]['request_key']);
  });

  testWidgets('no weight, nothing sent', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, isEmpty);
  });

  testWidgets('from the stock a location holds: a batch opened with no wage, each piece its own', (tester) async {
    final api = _Api();
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-from-stock')));
    await tester.pumpAndSettle();
    expect(find.text('وديعة المكتب'), findsNothing, reason: 'an office deposit is not coded');
    await tester.tap(find.byKey(const Key('coding-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المعرض').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-category')));
    await tester.pumpAndSettle();
    expect(find.text('خواتم 21'), findsNothing, reason: 'only categories tracked by the piece');
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('المتاح للترميز: 120.00'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('coding-weight')), '50');
    expect(find.byKey(const Key('coding-wage')), findsNothing, reason: 'a batch takes no wage');
    expect(find.byKey(const Key('coding-wage-by-piece')), findsOneWidget);
    await tester.tap(find.byKey(const Key('coding-open')));
    await tester.pumpAndSettle();
    expect(api.opened.single, {'safe_box_id': 3, 'category_id': 28, 'weight': 50.0});

    // no wage, nothing sent
    await tester.enterText(find.byKey(const Key('piece-weight')), '12.4');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent, isEmpty);

    // per gram
    await tester.enterText(find.byKey(const Key('piece-wage')), '20');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['coding_id'], 5);
    expect(api.sent.single.containsKey('line_id'), isFalse);
    expect((api.sent.single['wage'], api.sent.single['wage_whole']), (20.0, false));
    expect(find.byKey(const Key('piece-wage')), findsOneWidget, reason: 'the next piece writes its own');

    // the piece's whole
    await tester.tap(find.text('أجرة القطعة كلها'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('piece-weight')), '10');
    await tester.enterText(find.byKey(const Key('piece-wage')), '300');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect((api.sent.last['wage'], api.sent.last['wage_whole']), (300.0, true));
  });

  testWidgets('from 2027 a batch\'s piece takes its pool\'s average: shown, not asked', (tester) async {
    final api = _Api()..fromPool = true;
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    tester.view.physicalSize = const Size(1400, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: PieceStationScreen(api: api)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('station-from-stock')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('المعرض').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('coding-category')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنجرة ذهب 21').last);
    await tester.pumpAndSettle();
    expect(find.text('لا أجرة للدفعة: كل قطعة تأخذ متوسط أجور تصنيفها.'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('coding-weight')), '50');
    await tester.tap(find.byKey(const Key('coding-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('piece-wage')), findsNothing, reason: 'no wage written');
    expect(find.byKey(const Key('piece-wage-kind')), findsNothing);
    expect(find.descendant(of: find.byKey(const Key('piece-wage-from-pool')), matching: find.text('20.00 للجرام')),
        findsOneWidget);
    await tester.enterText(find.byKey(const Key('piece-weight')), '10');
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
    expect(api.sent.single['coding_id'], 5);
    expect(api.sent.single.containsKey('wage'), isFalse, reason: 'the server takes it from the pool');
  });

  Future<void> register(WidgetTester tester, [String weight = '14.37']) async {
    await tester.enterText(find.byKey(const Key('piece-weight')), weight);
    await tester.tap(find.byKey(const Key('piece-register')));
    await tester.pumpAndSettle();
  }

  testWidgets('registered, its label printed at once: printed, its tag read back', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.text('الطابعة جاهزة'), findsOneWidget);
    await register(tester);
    expect(api.sent, hasLength(1), reason: 'the piece saved first');
    expect((api.printed.single['piece_id'], api.printed.single['run'], api.printed.single['kind']), (101, true, 'first'));
    expect(api.printed.single['request_key'], isNotEmpty);
    expect(find.descendant(of: find.byKey(const Key('station-last')), matching: find.text('مطبوعة · الجيل 1')),
        findsOneWidget);
    expect(find.byKey(const Key('station-tag-101')), findsNothing, reason: 'no tag mounted by a button');
  });

  testWidgets('the last piece shows its label as it prints, both faces', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester);
    expect(find.byKey(const Key('label-preview-first')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const Key('label-preview-first')), matching: find.text('21K · 14.37g')),
        findsOneWidget);
  });

  testWidgets('«تسجيل فقط»: the piece saved, its label waiting', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.tap(find.text('تسجيل فقط'));
    await tester.pumpAndSettle();
    await register(tester);
    expect(api.printed.single['run'], isFalse);
    expect(find.byKey(const Key('label-run-101')), findsWidgets, reason: 'waiting: printed when asked');
    expect(find.textContaining('تعذّرت طباعة البطاقة'), findsNothing, reason: 'nothing failed');
  });

  testWidgets('a printer that fails stops no one: said, then tried again', (tester) async {
    final api = _Api()..printOutcome = 'failed';
    await _open(tester, api);
    await register(tester);
    expect(find.text('تم تسجيل القطعة بنجاح، لكن تعذّرت طباعة البطاقة. أُضيفت إلى قائمة انتظار الطباعة.'),
        findsOneWidget);
    expect(find.textContaining('انتهت الملصقات'), findsWidgets);
    await tester.tap(find.byKey(const Key('label-retry-101')).first);
    await tester.pumpAndSettle();
    expect(api.runs, hasLength(1));
    expect(find.text('مطبوعة · الجيل 2'), findsWidgets);
    await register(tester, '10');
    expect(api.sent, hasLength(2), reason: 'the next piece coded as before');
  });

  testWidgets('an unknown end settled by the reader: its own value adopted', (tester) async {
    final api = _Api()..printOutcome = 'needs_attention';
    await _open(tester, api);
    await register(tester);
    await tester.tap(find.byKey(const Key('label-resolve-101')).first);
    await tester.pumpAndSettle();
    expect(find.textContaining('في تطبيق الملاحظات على القارئ'), findsOneWidget,
        reason: 'the reader types on its own screen: said where its code is read');
    await tester.enterText(find.byKey(const Key('resolve-read')), '4B4A00010000000000000121');
    await tester.tap(find.byKey(const Key('resolve-adopt')));
    await tester.pumpAndSettle();
    expect(api.resolved.single['read_value'], '4B4A00010000000000000121');
    expect(find.text('مطبوعة · الجيل 1'), findsWidgets);
  });

  testWidgets('an unknown end where no label came out: failed, tried again with a new label', (tester) async {
    final other = _Api()..printOutcome = 'needs_attention';
    await _open(tester, other);
    await register(tester);
    await tester.tap(find.byKey(const Key('label-resolve-101')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('resolve-no-label')));
    await tester.pumpAndSettle();
    expect(other.resolved.single['no_label'], isTrue);
    expect(find.byKey(const Key('label-retry-101')), findsWidgets, reason: 'failed: tried again with a new label');
  });

  testWidgets('a reprint asks its reason', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester);
    await tester.tap(find.byKey(const Key('label-reprint-101')).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('confirm-action')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('confirm-reason')), 'تلفت البطاقة');
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect((api.printed.last['kind'], api.printed.last['reason']), ('reprint', 'تلفت البطاقة'));
  });

  testWidgets('the printer stopped and the labels waiting are said; the failures handled from the bar',
      (tester) async {
    final api = _Api()
      ..printerReady = false
      ..counts = {'pending': 2, 'failed': 1, 'needs_attention': 0}
      ..openJobs = [
        {'id': 9, 'item_id': 101, 'item_code': 'KJ-000121', 'status': 'failed',
         'last_attempt': {'id': 509, 'message': 'انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'}},
      ];
    await _open(tester, api);
    expect(find.text('انتهت الملصقات: ضع لفة جديدة ثم أعد المحاولة'), findsOneWidget);
    expect(find.text('بانتظار البطاقة 2 · فاشلة 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('station-failures')));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: find.byKey(const Key('station-failures-sheet')),
        matching: find.text('إعادة المحاولة')));
    await tester.pumpAndSettle();
    expect(api.runs, [9]);
  });

  testWidgets('the printer\'s bar reads it again by itself: back from a cut cable, «جاهزة» with no press',
      (tester) async {
    final api = _Api()..printerReady = false;
    await _open(tester, api);
    expect(find.byKey(const Key('station-printer')), findsOneWidget);
    expect(find.text('الطابعة جاهزة'), findsNothing);
    final asked = api.statusAsked;
    api.printerReady = true;                       // the cable back
    await tester.pump(const Duration(seconds: 16));          // the station asks every 15 seconds
    await tester.pumpAndSettle();
    expect(api.statusAsked, greaterThan(asked));
    expect(find.text('الطابعة جاهزة'), findsOneWidget);
  });

  testWidgets('the printer not ready: its words said, the piece\'s label waiting', (tester) async {
    final api = _Api()..printOutcome = 'not_ready';
    await _open(tester, api);
    await register(tester);
    expect(find.textContaining('تعذّرت طباعة البطاقة: الطابعة لا تردّ'), findsOneWidget);
    expect(find.byKey(const Key('label-run-101')), findsWidgets, reason: 'waiting: printed when it answers');
  });

  testWidgets('another label printing: its turn asked again by itself, then printed -- nothing pressed',
      (tester) async {
    PieceLabelActions.busyPause = Duration.zero;
    addTearDown(() => PieceLabelActions.busyPause = const Duration(milliseconds: 1500));
    final api = _Api()..busyFor = 3;
    await _open(tester, api);
    await register(tester);
    expect(api.runs, hasLength(3), reason: 'busy at its request and twice more, then its turn came');
    expect(find.textContaining('مطبوعة'), findsWidgets);
    expect(find.textContaining('تعذّرت'), findsNothing, reason: 'busy is not a failure');
  });

  // ── ر1: the mistakes the station stops before they are pieces ──

  testWidgets('a weight ten times the line\'s pieces is asked: corrected, nothing sent', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester, '5');
    await register(tester, '5.2');
    expect(api.sent, hasLength(2));
    await register(tester, '51');
    expect(find.byKey(const Key('weight-unusual')), findsOneWidget);
    expect(find.textContaining('5.10 جم؟'), findsOneWidget, reason: 'the tenth offered: 51 typed for 5.1');
    await tester.tap(find.byKey(const Key('weight-fix')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2), reason: 'a piece is never deleted: the doubt asked before it is one');
    await register(tester, '5.1');
    expect(find.byKey(const Key('weight-unusual')), findsNothing);
    expect(api.sent, hasLength(3));
    expect(api.sent.last['weight'], 5.1);
  });

  testWidgets('a weight unusual but true is sent when said so', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester, '5');
    await register(tester, '5.2');
    await register(tester, '1.2');
    expect(find.byKey(const Key('weight-unusual')), findsOneWidget);
    await tester.tap(find.byKey(const Key('weight-confirm')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(3));
    expect(api.sent.last['weight'], 1.2);
  });

  testWidgets('one piece is no average: the second weight is not asked', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await register(tester, '5');
    await register(tester, '15');
    expect(find.byKey(const Key('weight-unusual')), findsNothing);
    expect(api.sent, hasLength(2));
  });

  testWidgets('the choices kept for the next piece are said where its weight is typed', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.text('بلا موديل · طباعة تلقائية'), findsOneWidget);
    await tester.tap(find.text('تسجيل فقط'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('station-current')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('station-current'))).data, 'بلا موديل · تسجيل فقط');
  });

  testWidgets('on a phone nothing is squeezed: the bar\'s words, the weight, the button, each piece', (tester) async {
    final api = _Api();
    await _open(tester, api, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byKey(const Key('station-printer'))).width, greaterThan(250),
        reason: 'the printer\'s words on a line of their own, not one letter a line');
    expect(tester.getSize(find.byKey(const Key('piece-weight'))).width, greaterThan(300));
    expect(tester.getSize(find.byKey(const Key('piece-register'))).width, greaterThan(300));
    await register(tester, '5');
    expect(tester.takeException(), isNull);
    final row = find.byKey(const Key('station-piece-101'));
    await tester.dragUntilVisible(row, find.byType(ListView).last, const Offset(0, -200));
    await tester.pumpAndSettle();
    final code = find.descendant(of: row, matching: find.text('KJ-000121'));
    expect(tester.getSize(code).width, greaterThan(250), reason: 'its number readable, its actions under it');
    final last = find.descendant(of: find.byKey(const Key('station-last')), matching: find.text('KJ-000121'));
    expect(tester.getSize(last).width, greaterThan(250));
  });
}
