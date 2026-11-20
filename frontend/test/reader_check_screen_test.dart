// «فحص القارئ» (ADR-085 ت0; the owner, 21 Nov 2026): a handheld reader
// types each tag it reads into the page's field, as a keyboard would. The
// page counts the reads -- new and repeated -- says what the reader puts
// between two (Enter, nothing...), and asks the server what each value is.
// Nothing is written.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reader_check_screen.dart';
import 'package:frontend/theme/app_theme.dart';

const _active = '4B4A00010000000000999960';
const _stopped = '4B4A00010000000000999961';

class _Api extends ApiService {
  final asked = <String>[];

  @override
  Future<Map<String, dynamic>> pieceByTag(String value) async {
    asked.add(value);
    if (value == _active) {
      return {'piece': {'item_code': 'KJ-999960'}, 'location': {'name': 'المعرض'}};
    }
    throw const ApiException(statusCode: 404, code: 'tag_stopped',
        message: 'رقاقة ملغاة — القطعة KJ-999961 — الجيل 0001 — لا تُحتسب في الجرد');
  }

  @override
  Future<Map<String, dynamic>> lookupPiece(String code) async {
    asked.add(code);
    return {'piece': {'item_code': code}, 'location': {'name': 'المعرض'}};
  }
}

/// The test's own time, moved by the test.
int _ms = 0;

Future<void> _open(WidgetTester tester, _Api api) async {
  _ms = 0;
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(theme: LightTheme.theme, home: ReaderCheckScreen(api: api, elapsed: () => _ms)));
  await tester.pumpAndSettle();
}

String _said(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(Key(key))).data!;

void main() {
  testWidgets('each read counted as it comes: new and repeated, the separator said, each asked once', (tester) async {
    final api = _Api();
    await _open(tester, api);
    final field = find.byKey(const Key('reader-field'));
    await tester.enterText(field, '$_active\n');
    await tester.enterText(field, '$_active\n$_stopped\n');
    await tester.enterText(field, '$_active\n$_stopped\n$_active\n');
    await tester.pumpAndSettle();
    expect((_said(tester, 'reader-reads'), _said(tester, 'reader-unique'), _said(tester, 'reader-repeats')),
        ('3', '2', '1'));
    expect(_said(tester, 'reader-separator'), 'Enter');
    expect(api.asked, [_active, _stopped], reason: 'a value asked once, however often read');
    expect(find.textContaining('KJ-999960 — المعرض — رقاقة معتمدة'), findsOneWidget);
    expect(find.textContaining('رقاقة ملغاة'), findsOneWidget, reason: 'the server\'s words for a tag not counted');
  });

  testWidgets('a reader that puts nothing between two reads is read too, and said so', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('reader-field')), '${_active.toLowerCase()}$_stopped');
    await tester.pumpAndSettle();
    expect(_said(tester, 'reader-reads'), '2');
    expect(_said(tester, 'reader-separator'), 'بلا فاصل');
  });

  testWidgets('a label\'s printed code is a read as well, and «من جديد» starts again', (tester) async {
    final api = _Api();
    await _open(tester, api);
    await tester.enterText(find.byKey(const Key('reader-field')), 'KJ-999960\n');
    await tester.pumpAndSettle();
    expect(find.textContaining('KJ-999960 — المعرض — الرمز المطبوع'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reader-clear')));
    await tester.pumpAndSettle();
    expect((_said(tester, 'reader-reads'), _said(tester, 'reader-unique')), ('0', '0'));
    expect(find.byKey(const Key('reader-value-KJ-999960')), findsNothing);
    await tester.enterText(find.byKey(const Key('reader-field')), '$_active\n');
    await tester.pumpAndSettle();
    expect(_said(tester, 'reader-reads'), '1', reason: 'counted again from the first read');
  });

  testWidgets('its words on the top bar are seen: the bar\'s ink, not the bar\'s colour', (tester) async {
    await _open(tester, _Api());
    Color? ink(Key key) => tester
        .widget<RichText>(find.descendant(of: find.byKey(key), matching: find.byType(RichText)).first)
        .text
        .style
        ?.color;
    final bar = Theme.of(tester.element(find.byType(AppBar))).appBarTheme;
    expect(ink(const Key('reader-clear')), bar.foregroundColor);
    expect(ink(const Key('reader-clear')), isNot(bar.backgroundColor));
  });

  testWidgets('each press of the reader is its own: its reads and the new among them; the button counted',
      (tester) async {
    final api = _Api();
    await _open(tester, api);
    final field = find.byKey(const Key('reader-field'));
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);          // held: its repeats one press
    await tester.enterText(field, '$_active\n$_stopped\n');     // one press, two tags at once
    _ms += 1000;                                                // a second later
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.enterText(field, '$_active\n$_stopped\n$_active\n$_stopped\n');   // pressed again: the same two
    await tester.pumpAndSettle();
    expect((_said(tester, 'reader-presses'), _said(tester, 'reader-button')), ('2', '2'));
    expect(_said(tester, 'reader-press-1'), 'الضغطة 1: 2 رقاقة · جديدة 2');
    expect(_said(tester, 'reader-press-2'), 'الضغطة 2: 2 رقاقة · جديدة 0');
    expect(find.textContaining('في 2 من 2 ضغطة · KJ-999960'), findsOneWidget);
    expect((_said(tester, 'reader-reads'), _said(tester, 'reader-unique')), ('4', '2'));
  });
}
