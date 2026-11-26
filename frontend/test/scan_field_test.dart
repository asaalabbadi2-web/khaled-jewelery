// «امسح القطعة» -- ScanField, the reader's door beside a screen's fields (the owner, 26 Nov 2026: «خلل
// في الضغط والتمرير ويظهر خصوصًا في الشاشات الصغيرة»; his five conditions before it was built): no
// on-screen keyboard; the focus never taken from a field the user chose; the screen never pulled; a
// character typed rebuilds nothing of the screen; a value whole with no Enter, its last digits not
// cut, held on one label taken once; typed by hand taken once, then the reader's again; one door a
// screen.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/scan_field.dart';

import 'support/reader_door.dart';

void main() {
  final asked = <(String, bool)>[];
  var built = 0;
  Completer<void>? gate;

  Future<ScanSaid> onValue(String value, {required bool typed}) async {
    asked.add((value, typed));
    if (gate != null) await gate!.future;
    return (ok: true, words: 'قُرئ $value');
  }

  Future<void> open(WidgetTester tester, {Size size = const Size(400, 800), bool twoDoors = false}) async {
    asked.clear();
    built = 0;
    gate = null;
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Scaffold(
        body: Builder(builder: (context) {
          built++; // the screen around the field
          return ListView(children: [
            for (var i = 0; i < 6; i++) SizedBox(height: 60, child: Text('above $i')),
            ScanField(keyBase: 'door', label: 'امسح القطعة', onValue: onValue),
            if (twoDoors) ScanField(keyBase: 'second', label: 'ثانٍ', onValue: onValue),
            const TextField(key: Key('typed')),
            for (var i = 0; i < 30; i++) SizedBox(height: 60, child: Text('below $i')),
          ]);
        }),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('read: no on-screen keyboard, a tag whole at its last character with no Enter, the field emptied',
      (tester) async {
    await open(tester);
    expect(focused(tester, 'door'), isTrue, reason: 'the reader heard at once');
    expect(asksNoKeyboard(tester), isTrue);
    await readerTypes(tester, 'door', '4B4A00010000000000000005');
    expect(asked, [('4B4A00010000000000000005', false)]);
    expect(doorOf(tester, 'door').controller.text, isEmpty, reason: 'ready for the next');
    expect(find.text('قُرئ 4B4A00010000000000000005'), findsOneWidget, reason: 'what was said, under it');
  });

  testWidgets('a printed number waits for the reader\'s quiet: its seventh digit not cut', (tester) async {
    await open(tester);
    await readerTypes(tester, 'door', 'KJ-1000005');
    expect(asked, [('KJ-1000005', false)]);
  });

  testWidgets('held on one label: the reader sends it again and again, taken once; a moment later, again',
      (tester) async {
    await open(tester);
    for (var i = 0; i < 3; i++) {                                  // every ~50 ms while held
      await tester.enterText(find.byKey(const Key('door')), '4B4A00010000000000000005');
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(asked.length, 1, reason: 'one label held');
    await tester.pump(const Duration(seconds: 1));
    await readerTypes(tester, 'door', '4B4A00010000000000000005');
    expect(asked.length, 2, reason: 'read again later: the screen says what it is');
  });

  testWidgets('read while the last is still asked: in order, none lost', (tester) async {
    await open(tester);
    gate = Completer<void>();
    await readerTypes(tester, 'door', '4B4A00010000000000000005');
    await readerTypes(tester, 'door', '4B4A00010000000000000006');
    expect(asked.length, 1, reason: 'the second waits for the first');
    gate!.complete();
    await tester.pumpAndSettle();
    expect([for (final a in asked) a.$1], ['4B4A00010000000000000005', '4B4A00010000000000000006']);
  });

  testWidgets('a chip that is not ours is said, not asked', (tester) async {
    await open(tester);
    await readerTypes(tester, 'door', 'E28011700000020A1B2C3D4E');
    expect(asked, isEmpty);
    expect(find.text('قراءة ليست لبطاقة من بطاقاتنا'), findsOneWidget);
    expect(doorOf(tester, 'door').controller.text, isEmpty);
  });

  testWidgets('a field the user chose keeps its focus; a touch on nothing gives it back to the door', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('typed')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(focused(tester, 'typed'), isTrue, reason: 'never taken from the field the user chose');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(focused(tester, 'door'), isTrue, reason: 'nothing held it: the door again');
  });

  testWidgets('the screen stays where it was scrolled: the door takes its focus back and is typed into in place',
      (tester) async {
    await open(tester);
    await tester.drag(find.text('below 2'), const Offset(0, -500));
    await tester.pumpAndSettle();
    double offset() => tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;
    final where = offset();
    final below = tester.getTopLeft(find.text('below 10')).dy;
    FocusManager.instance.primaryFocus?.unfocus();             // the owner's reader drops it after a read
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(focused(tester, 'door'), isTrue);
    await readerTypes(tester, 'door', '4B4A00010000000000000005');
    expect(asked.length, 1);
    expect(offset(), where, reason: 'not pulled to the field');
    expect(tester.getTopLeft(find.text('below 10')).dy, below, reason: 'nothing below it moved: its words\' line was kept');
  });

  testWidgets('a character typed rebuilds nothing of the screen; the value whole, it is the field\'s alone',
      (tester) async {
    await open(tester);
    final before = built;
    await readerTypes(tester, 'door', '4B4A00010000000000000005');
    expect(asked.length, 1);
    expect(built, before, reason: '24 characters and its answer: the screen around it not built once');
  });

  testWidgets('typed by hand: its keyboard, nothing taken while typed, taken once, the reader\'s again',
      (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('door-keyboard')));
    await tester.pumpAndSettle();
    expect(focused(tester, 'door'), isTrue);
    expect(asksNoKeyboard(tester), isFalse, reason: 'its keyboard opened, to type');
    await tester.enterText(find.byKey(const Key('door')), 'KJ-000004');
    await tester.pump(const Duration(milliseconds: 500));
    expect(asked, isEmpty, reason: 'typed is not taken while it is typed');
    await tester.testTextInput.receiveAction(TextInputAction.done);   // Enter
    await tester.pumpAndSettle();
    expect(asked, [('KJ-000004', true)]);
    expect(focused(tester, 'door'), isTrue);
    expect(asksNoKeyboard(tester), isTrue, reason: 'the reader\'s door again, the keyboard closed');
    await tester.tap(find.byKey(const Key('door-keyboard')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('door')), '7');
    await tester.tap(find.byKey(const Key('door-take')));
    await tester.pumpAndSettle();
    expect(asked, [('KJ-000004', true), ('7', true)], reason: '«✓» takes it once, as written');
    expect(doorOf(tester, 'door').controller.text, isEmpty);
  });

  testWidgets('typing left by a touch elsewhere: it is the reader\'s again, what was typed kept', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('door-keyboard')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('door')), '12');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(focused(tester, 'door'), isTrue);
    expect(asksNoKeyboard(tester), isTrue);
    expect(doorOf(tester, 'door').controller.text, '12');
    expect(asked, isEmpty);
  });

  testWidgets('two doors holding the focus on one screen is said at once', (tester) async {
    await open(tester, twoDoors: true);
    expect('${tester.takeException()}', contains('2 reader doors hold the focus on one screen'));
  });
}
