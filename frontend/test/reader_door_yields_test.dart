// The reader's door and the focus the user gives elsewhere (the owner, 28 Nov 2026: «بعد اعطاء
// التركيز للقارئ ... لا تقبل نقل التركيز الى مكان اخر»). The door takes the focus back when nothing
// holds it; it never takes it from what the user gave it to -- a field, a button, a box, a menu.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/scan_field.dart';

final _box = FocusNode(debugLabel: 'box');
final _button = FocusNode(debugLabel: 'button');

Future<void> _screen(WidgetTester tester, {List<Widget> more = const []}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(children: [
        ScanField(keyBase: 'door', label: 'امسح القطعة', onValue: (v, {required typed}) async => null),
        Checkbox(key: const Key('box'), focusNode: _box, value: false, onChanged: (_) {}),
        ElevatedButton(key: const Key('button'), focusNode: _button, onPressed: () {}, child: const Text('حفظ')),
        const TextField(key: Key('other-field')),
        ...more,
      ]),
    ),
  ));
  await tester.pumpAndSettle();
}

FocusNode? get _focused => FocusManager.instance.primaryFocus;

/// The door's own node -- not a button inside its field.
bool _isDoor(WidgetTester tester) => _focused == tester.widget<TextField>(find.byKey(const Key('door'))).focusNode;

void main() {
  testWidgets('the door holds the focus when the screen opens', (tester) async {
    await _screen(tester);
    expect(_isDoor(tester), isTrue);
  });

  testWidgets('Tab moves the focus on from the door, and it stays where Tab put it', (tester) async {
    await _screen(tester);
    // past the door and the buttons inside it, to what follows it
    for (var i = 0; i < 4 && !(_focused == _box || _focused == _button); i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
    }
    final there = _focused;
    expect(there == _box || there == _button, isTrue, reason: 'Tab moved it on, past the door');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_focused, same(there), reason: 'not taken back from where the keyboard put it');
  });

  testWidgets('a box or a button given the focus keeps it', (tester) async {
    await _screen(tester);
    for (final node in [_box, _button]) {
      node.requestFocus();
      await tester.pump();
      expect(_focused, same(node));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_focused, same(node), reason: '${node.debugLabel} keeps it');
    }
  });

  testWidgets('a menu that is not a page keeps the focus while open', (tester) async {
    final controller = MenuController();
    await _screen(tester, more: [
      MenuAnchor(
        controller: controller,
        menuChildren: [MenuItemButton(key: const Key('item'), onPressed: () {}, child: const Text('بند'))],
        child: const SizedBox.shrink(),
      ),
    ]);
    controller.open();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.isOpen, isTrue, reason: 'its focus not taken by the door: it stays open');
  });

  testWidgets('another field the user chose keeps it', (tester) async {
    await _screen(tester);
    await tester.tap(find.byKey(const Key('other-field')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_focused?.context?.findAncestorWidgetOfExactType<TextField>()?.key, const Key('other-field'));
  });

  testWidgets('nothing holding the focus -- a touch on the blank -- it is the door\'s again', (tester) async {
    await _screen(tester);
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_isDoor(tester), isTrue);
  });

  testWidgets('a dialog closed: the door has it again', (tester) async {
    await _screen(tester);
    final context = tester.element(find.byType(Scaffold));
    showDialog<void>(context: context, builder: (_) => const AlertDialog(content: TextField(key: Key('in-dialog'))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('in-dialog')));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_isDoor(tester), isFalse, reason: 'the dialog\'s field keeps it');
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_isDoor(tester), isTrue);
  });

  _owned();
}

// ── the owner's review of the design (28 Nov 2026): its gates ─────────────────────────────────────────

void _owned() {
  // (1) Tab from one thing to the next, several times over: the reader never steps in.
  testWidgets('Tab after Tab across the screen: each stop keeps the focus', (tester) async {
    await _screen(tester, more: [
      Switch(key: const Key('switch'), value: false, onChanged: (_) {}),
      OutlinedButton(onPressed: () {}, child: const Text('إلغاء')),
    ]);
    final stops = <FocusNode?>[];
    for (var i = 0; i < 8; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final there = _focused;
      await tester.pump(const Duration(milliseconds: 400));
      expect(_focused, same(there), reason: 'stop $i kept: Tab put it there');
      stops.add(there);
    }
    expect(stops.toSet().length, greaterThan(3), reason: 'Tab went on across the screen');
  });

  // (2) A dropdown opened, walked in, closed: open while walked; the reader not in the way.
  testWidgets('a dropdown opened, walked by its keys, then closed', (tester) async {
    final dropdown = FocusNode(debugLabel: 'dropdown');
    await _screen(tester, more: [
      DropdownButton<int>(
        key: const Key('dropdown'),
        focusNode: dropdown,
        value: 1,
        items: const [
          DropdownMenuItem(value: 1, child: Text('واحد')),
          DropdownMenuItem(value: 2, child: Text('اثنان')),
          DropdownMenuItem(value: 3, child: Text('ثلاثة')),
        ],
        onChanged: (_) {},
      ),
    ]);
    await tester.tap(find.byKey(const Key('dropdown')));
    await tester.pumpAndSettle();
    expect(find.text('ثلاثة').hitTestable(), findsOneWidget, reason: 'open');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('ثلاثة').hitTestable(), findsOneWidget, reason: 'still open, walked in');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_focused, same(dropdown), reason: 'closed: the focus back where it was, and kept');
  });

  // (3) A dialog over a screen whose text field held the focus: closed, that field has it again.
  testWidgets('a dialog closed over a field the user was in: the field keeps it', (tester) async {
    await _screen(tester);
    await tester.tap(find.byKey(const Key('other-field')));
    await tester.pump();
    final field = _focused;
    final context = tester.element(find.byType(Scaffold));
    showDialog<void>(context: context, builder: (_) => const AlertDialog(content: Text('تنبيه')));
    await tester.pumpAndSettle();
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(_focused, same(field), reason: 'not taken by the reader');
  });

  // (4) The screen's shortcuts wrapper (AppDocumentShortcuts) is a scope: focus on it is nothing held.
  testWidgets('the focus on a scope alone -- a shortcuts wrapper -- is nothing held: the door has it', (tester) async {
    await _screen(tester);
    _focused!.unfocus(disposition: UnfocusDisposition.scope);
    await tester.pump();
    expect(_focused, isA<FocusScopeNode>(), reason: 'a scope, nothing in it');
    await tester.pump(const Duration(milliseconds: 400));
    expect(_isDoor(tester), isTrue);
  });

  // (5) A dialog over the door, closed: the door has it once -- no second, competing request.
  testWidgets('a dialog closed over the door: the door has it, once', (tester) async {
    await _screen(tester);
    final door = tester.widget<TextField>(find.byKey(const Key('door'))).focusNode!;
    final context = tester.element(find.byType(Scaffold));
    showDialog<void>(context: context,
        builder: (_) => const AlertDialog(content: TextField(key: Key('in-dialog'), autofocus: true)));
    await tester.pumpAndSettle();
    expect(door.hasPrimaryFocus, isFalse, reason: 'the dialog\'s field has it');
    var became = 0;
    var was = door.hasPrimaryFocus;
    void count() {
      if (door.hasPrimaryFocus && !was) became++;
      was = door.hasPrimaryFocus;
    }
    door.addListener(count);
    addTearDown(() => door.removeListener(count));
    Navigator.of(context).pop();
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    expect(door.hasPrimaryFocus, isTrue);
    expect(became, 1, reason: 'one move to the door, not two competing');
  });
}
