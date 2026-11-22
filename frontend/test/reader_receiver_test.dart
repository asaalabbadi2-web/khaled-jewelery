// «استقبال القارئ» beside other fields (the owner, 22 Nov 2026: in the sale invoice «بمجرد لمس الشاشة
// وضياع التركيز ... يصدر الجهاز صوت قراءة ولا يوجد قراءة»): the panel takes its focus back when nothing
// holds it -- a touch on the screen's blank -- and never from a field the user is typing in.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/reader_capture.dart';
import 'package:frontend/widgets/reader_receiver.dart';

void main() {
  late ReaderCapture capture;
  late FocusNode receiver;
  late FocusNode other;
  final read = <String>[];

  Future<void> open(WidgetTester tester) async {
    read.clear();
    capture = ReaderCapture(
      onEvents: (events) => read.addAll([for (final e in events) if (e.value != null) e.value!]),
      elapsed: () => 0,
      clearAfterRead: true,
    )..start();
    receiver = FocusNode();
    other = FocusNode();
    addTearDown(() {
      capture.dispose();
      receiver.dispose();
      other.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Scaffold(
        body: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
          child: Column(children: [
            ReaderReceiver(capture: capture, focusNode: receiver, fieldKey: const Key('rx')),
            TextField(key: const Key('typed'), focusNode: other),
            const SizedBox(key: Key('blank'), height: 300, width: double.infinity),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('a field the user types in keeps its focus', (tester) async {
    await open(tester);
    expect(receiver.hasFocus, isTrue, reason: 'focused on opening');
    await tester.tap(find.byKey(const Key('typed')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(other.hasFocus, isTrue, reason: 'never taken from the field the user chose');
    expect(receiver.hasFocus, isFalse);
  });

  testWidgets('a touch on the blank leaves nothing focused: the panel takes it back, and hears the reader', (tester) async {
    await open(tester);
    await tester.tap(find.byKey(const Key('typed')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('blank')));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(receiver.hasFocus, isTrue, reason: 'nothing held the focus: the reader\'s door again');
    await tester.enterText(find.byKey(const Key('rx')), 'KJ-000005');
    await tester.pumpAndSettle();
    expect(read, ['KJ-000005']);
  });

  // The owner, 22 Nov 2026: «لا يمكنك التمرير للأسفل» on the sale and «جرد بالمسح»: a finger on the screen
  // to scroll took the panel's focus, and the panel taking it back pulled the screen up to itself.
  testWidgets('scrolling down stays down: the panel keeps its focus and never pulls the screen to itself', (tester) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final capture = ReaderCapture(onEvents: (_) {}, elapsed: () => 0, clearAfterRead: true)..start();
    final focus = FocusNode();
    addTearDown(() {
      capture.dispose();
      focus.dispose();
    });
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Scaffold(
        body: ListView(controller: scroll, children: [
          ReaderReceiver(capture: capture, focusNode: focus, fieldKey: const Key('rx')),
          for (var i = 0; i < 40; i++) SizedBox(height: 60, child: Text('line $i')),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    await tester.drag(find.text('line 5'), const Offset(0, -900));
    await tester.pumpAndSettle();
    final down = scroll.offset;
    expect(down, greaterThan(500));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(scroll.offset, down, reason: 'where the finger left it');
    expect(focus.hasFocus, isTrue, reason: 'the reader still heard');
    focus.unfocus();                                   // lost anyway (the reader's own read did it, 21 Nov)
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue, reason: 'taken back');
    expect(scroll.offset, down, reason: 'taken back where it is, the screen not pulled up');
  });

  // The owner, 22 Nov 2026: «تنتقل من اللون الأخضر إلى البرتقالي باستمرار».
  testWidgets('unheard is shown only when it lasts: a field typed in for a second', (tester) async {
    await open(tester);
    String state() => tester.widget<Text>(find.byKey(const Key('reader-receiver-state'))).data!;
    await tester.tap(find.byKey(const Key('typed')));
    await tester.pump(const Duration(milliseconds: 500));
    expect(state(), 'القارئ جاهز — اضغط زرّه', reason: 'half a second: not yet said');
    await tester.pump(const Duration(milliseconds: 700));
    expect(state(), 'اضغط هنا ليستقبل القارئ', reason: 'unheard for a second: said');
  });

  testWidgets('its one-icon form hears the reader the same', (tester) async {
    read.clear();
    final capture = ReaderCapture(
      onEvents: (events) => read.addAll([for (final e in events) if (e.value != null) e.value!]),
      elapsed: () => 0,
      clearAfterRead: true,
    )..start();
    final focus = FocusNode();
    addTearDown(() {
      capture.dispose();
      focus.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Scaffold(
        appBar: AppBar(actions: [ReaderReceiver(capture: capture, focusNode: focus, fieldKey: const Key('rx'), compact: true)]),
      ),
    ));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    expect(find.byIcon(Icons.sensors), findsOneWidget, reason: 'heard: its icon says so');
    // The owner, 22 Nov 2026 (the screens by a designer's eye): a filled circle the size of the card's
    // buttons was taken for one of them. The reader's mark on no fill, a small dot its state.
    final dot = tester.widget<Container>(find.byKey(const Key('reader-receiver-dot')));
    expect((dot.decoration as BoxDecoration).color,
        AppSemanticColors.of(tester.element(find.byKey(const Key('reader-receiver-dot')))).ready.fg);
    expect(tester.getSize(find.byKey(const Key('reader-receiver-dot'))).width, lessThanOrEqualTo(12));
    expect(find.descendant(of: find.byKey(const Key('reader-receiver')), matching: find.byWidgetPredicate(
        (w) => w is Container && w.decoration is BoxDecoration && (w.decoration as BoxDecoration).shape == BoxShape.circle
            && w.key != const Key('reader-receiver-dot'))), findsNothing, reason: 'no filled circle like the buttons');
    expect(tester.getSize(find.byKey(const Key('reader-receiver'))).width, lessThanOrEqualTo(48), reason: 'one icon');
    await tester.enterText(find.byKey(const Key('rx')), 'KJ-000005');
    await tester.pumpAndSettle();
    expect(read, ['KJ-000005']);
  });
}

