// «تحقّق من بطاقة» (ADR-085 ت2 ج2): one label read -- its piece, its facts,
// where the books have it, its tag's state and generation in the server's
// words; an unsettled attempt's tag settled here by that very value.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/tag_check_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/bidi.dart';
import 'package:frontend/utils/scan_feedback.dart';

const _active = '4B4A00020000000000000101';
const _stopped = '4B4A00010000000000000101';
const _attempt = '4B4A00010000000000000301';
const _sold = '4B4A00010000000000000401';

class _Api extends ApiService {
  final resolved = <(int, Map<String, dynamic>)>[];
  final asked = <String>[];
  bool settledOne = false;

  @override
  Future<Map<String, dynamic>> pieceByTag(String value) async {
    asked.add(value);
    if (value == _active || (value == _attempt && settledOne)) {
      return {
        'piece': {'item_code': value == _active ? 'KJ-000101' : 'KJ-000301', 'weight': 12.40, 'stones_weight': 0.35,
                  'stones_kind': 'as_gold', 'in_stock': true, 'model': {'name': 'بنجرة الشمس'}, 'size': null},
        'tag': {'state': 'active', 'generation': value == _active ? 2 : 1},
        'location': {'name': 'الذهب المعروض'},
      };
    }
    if (value == _sold) {
      return {
        'piece': {'item_code': 'KJ-000401', 'weight': 9.10, 'stones_weight': 0, 'in_stock': false},
        'tag': {'state': 'active', 'generation': 1},
        'location': null,
        'out': {'state': 'sold', 'date': '2026-11-21', 'words': 'ليست في المخزون — بيعت 2026-11-21'},
      };
    }
    if (value == _stopped) {
      throw const ApiException(statusCode: 404, code: 'tag_stopped',
          message: 'رقاقة ملغاة — القطعة KJ-000101 — الجيل 0001 — لا تُحتسب في الجرد',
          details: {'tag': {'state': 'stopped', 'item_code': 'KJ-000101', 'generation': 1}});
    }
    throw const ApiException(statusCode: 404, code: 'tag_unconfirmed',
        message: 'رقاقة من محاولة لم تُعتمد — القطعة KJ-000301 — الجيل 0001 — أتلفها',
        details: {'tag': {'state': 'unconfirmed', 'item_code': 'KJ-000301', 'attempt_id': 77, 'unsettled': true}});
  }

  @override
  Future<Map<String, dynamic>> resolvePrintAttempt(int attemptId, Map<String, dynamic> body) async {
    resolved.add((attemptId, body));
    settledOne = true;
    return {'job': {}};
  }
}

int _ms = 0;

Future<void> _open(WidgetTester tester, _Api api) async {
  _ms = 0;
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: TagCheckScreen(api: api, elapsed: () => _ms)));
  await tester.pumpAndSettle();
}

Future<void> _read(WidgetTester tester, String value) async {
  await tester.enterText(find.byKey(const Key('check-field')), '$value\n');
  await tester.pumpAndSettle();
}

String _said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  // The owner, 22 Nov 2026 (the screens by a designer's eye): the verdict heads the card -- its words, its
  // colour and its own icon -- and the tag drops to a small line; its generation only where it matters.
  bool verdictIcon(WidgetTester tester, String value, IconData icon) =>
      find.descendant(of: find.byKey(Key('check-verdict-$value')), matching: find.byIcon(icon)).evaluate().isNotEmpty;

  testWidgets('an adopted tag: «in stock» and where heads the card; its tag a small line', (tester) async {
    await _open(tester, _Api());
    await _read(tester, _active);
    expect(find.text('KJ-000101'), findsOneWidget);
    expect(_said(tester, 'check-verdict-text-$_active'), 'في المخزون — الذهب المعروض');
    expect(verdictIcon(tester, _active, Icons.verified_outlined), isTrue);
    expect(find.text('12.40 جم · فصوص 0.35 جم · بنجرة الشمس'), findsOneWidget);
    expect(_said(tester, 'check-tag-$_active'), 'رقاقة معتمدة', reason: 'no generation where it does not matter');
  });

  testWidgets('a sold piece: how it left heads the card, its own icon, its date never reversed', (tester) async {
    await _open(tester, _Api());
    await _read(tester, _sold);
    expect(find.text('KJ-000401'), findsOneWidget);
    expect(_said(tester, 'check-verdict-text-$_sold'), isolateLatin('ليست في المخزون — بيعت 2026-11-21'));
    expect(verdictIcon(tester, _sold, Icons.sell_outlined), isTrue, reason: 'sold, said by its own icon');
    expect(find.byIcon(Icons.verified_outlined), findsNothing, reason: 'a piece sold is not a piece found');
    expect(_said(tester, 'check-tag-$_sold'), 'رقاقة معتمدة', reason: 'its tag is sound: not the warning');
  });

  testWidgets('the system\'s tone: a piece in stock, and a label to look at', (tester) async {
    final said = <bool>[];
    final before = ScanFeedback.say;
    ScanFeedback.say = said.add;
    addTearDown(() => ScanFeedback.say = before);
    await _open(tester, _Api());
    await _read(tester, _active);
    _ms += 1000;
    await _read(tester, _sold);
    _ms += 1000;
    await _read(tester, _stopped);
    expect(said, [true, false, false], reason: 'in stock; sold; a stopped tag');
  });

  testWidgets('a stopped tag is said in the server\'s words, nothing to settle', (tester) async {
    await _open(tester, _Api());
    await _read(tester, _stopped);
    expect(_said(tester, 'check-verdict-text-$_stopped'),
        isolateLatin('رقاقة ملغاة — القطعة KJ-000101 — الجيل 0001 — لا تُحتسب في الجرد'));
    expect(verdictIcon(tester, _stopped, Icons.block), isTrue);
    expect(find.byKey(const Key('check-settle-$_stopped')), findsNothing);
  });

  testWidgets('an unsettled attempt\'s tag is settled by the value read, then said adopted', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _read(tester, _attempt);
    await tester.tap(find.byKey(const Key('check-settle-$_attempt')));
    await tester.pumpAndSettle();
    expect(api.resolved.single.$1, 77);
    expect(api.resolved.single.$2, {'read_value': _attempt}, reason: 'the reader\'s value; the server matches it');
    expect(_said(tester, 'check-verdict-text-$_attempt'), 'في المخزون — الذهب المعروض');
    expect(_said(tester, 'check-tag-$_attempt'), 'رقاقة معتمدة');
  });

  // ── each press its own check (the owner, 21 Nov 2026) ──

  testWidgets('held on one label: the field never piles its codes, the label asked once', (tester) async {
    final api = _Api();
    await _open(tester, api);
    final field = find.byKey(const Key('check-field'));
    for (var i = 0; i < 4; i++) {
      // a one-line field takes no Enter: the reader's codes would follow one another
      await tester.enterText(field, '${tester.widget<TextField>(field).controller!.text}$_active');
      await tester.pump();
      expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'emptied after each code taken');
      expect(find.textContaining('آخر قراءة:'), findsOneWidget, reason: 'what was read said under it');
      expect(find.textContaining(_active), findsNothing, reason: 'never the tag\'s raw 24 characters');
    }
    await tester.pumpAndSettle();
    expect(api.asked, [_active], reason: 'one press, one label, asked once');
    expect(find.byKey(const Key('check-$_active')), findsOneWidget);
  });

  testWidgets('a new press empties the screen: the next label alone', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _read(tester, _active);
    _ms = 2000;
    await _read(tester, _stopped);
    expect(find.byKey(const Key('check-$_active')), findsNothing, reason: 'the last press\'s label gone');
    expect(find.byKey(const Key('check-$_stopped')), findsOneWidget);
  });

  testWidgets('the reader\'s button alone empties it, and «مسح» does', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await _read(tester, _active);
    _ms = 2000;
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('check-$_active')), findsNothing, reason: 'one press of the button: ready for another piece');
    _ms = 4000;
    await _read(tester, _active);
    expect(find.byKey(const Key('check-$_active')), findsOneWidget);
    await tester.tap(find.byKey(const Key('check-clear')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('check-$_active')), findsNothing);
  });

  // ── «استقبال القارئ» (the owner, 21 Nov 2026) ──

  testWidgets('the receiver says whether the reader is heard; a tap on it hears it again', (tester) async {
    await _open(tester, _Api());
    String state() => tester.widget<Text>(find.byKey(const Key('reader-receiver-state'))).data!;
    expect(state(), 'القارئ جاهز — اضغط زرّه', reason: 'its field focused on opening');
    tester
        .widget<EditableText>(find.descendant(of: find.byKey(const Key('check-field')), matching: find.byType(EditableText)))
        .focusNode
        .unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));     // its focus changed -- before it is taken back
    expect(state(), 'القارئ جاهز — اضغط زرّه', reason: 'a moment unheard is not shown: no green to orange and back');
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(state(), 'القارئ جاهز — اضغط زرّه', reason: 'its focus lost after a read on the reader: taken back by itself');
    await tester.tap(find.byKey(const Key('reader-receiver')));
    await tester.pumpAndSettle();
    expect(state(), 'القارئ جاهز — اضغط زرّه');
  });

  testWidgets('its field opens no keyboard, is not seen, and the last read is said on the panel', (tester) async {
    await _open(tester, _Api());
    final field = tester.widget<TextField>(find.byKey(const Key('check-field')));
    expect(field.keyboardType, TextInputType.none, reason: 'the reader types; the screen needs no keyboard');
    final hidden = tester.widget<Opacity>(find.ancestor(of: find.byKey(const Key('check-field')), matching: find.byType(Opacity)).first);
    expect(hidden.opacity, 0);
    await _read(tester, _active);
    expect(tester.widget<Text>(find.byKey(const Key('reader-receiver-last'))).data,
        isolateLatin('آخر قراءة: KJ-000101 · الضغطة 1'),
        reason: 'the piece the server named, not the tag\'s raw value (the owner, 22 Nov 2026)');
  });
}

