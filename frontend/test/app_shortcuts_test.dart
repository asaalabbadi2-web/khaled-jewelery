import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/app_shortcuts.dart';

/// UI-6 (ADR-049): the same keys mean the same thing on every document and
/// list screen.
void main() {
  Future<void> openDocument(
    WidgetTester tester, {
    required VoidCallback onSave,
    VoidCallback? onAddLine,
    bool Function()? mayLeave,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => PopScope(
                    canPop: mayLeave?.call() ?? true,
                    child: AppDocumentShortcuts(
                      onSave: onSave,
                      onAddLine: onAddLine,
                      child: const Scaffold(
                        body: Column(children: [Text('document'), TextField()]),
                      ),
                    ),
                  ),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
  }) async {
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+S saves and Ctrl+Enter adds a line, even with a field '
      'left behind', (tester) async {
    var saved = 0, lines = 0;
    await openDocument(tester, onSave: () => saved++, onAddLine: () => lines++);
    await tester.tap(find.byType(TextField));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    await press(tester, LogicalKeyboardKey.keyS, control: true);
    await press(tester, LogicalKeyboardKey.enter, control: true);
    expect((saved, lines), (1, 1));
  });

  testWidgets('Esc goes back when nothing would be lost', (tester) async {
    await openDocument(tester, onSave: () {}, mayLeave: () => true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('document'), findsNothing);
  });

  testWidgets('Esc goes through the screen\'s own guard', (tester) async {
    await openDocument(tester, onSave: () {}, mayLeave: () => false);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('document'), findsOneWidget, reason: 'the guard holds');
  });

  testWidgets('F1 says the keys', (tester) async {
    await openDocument(tester, onSave: () {}, onAddLine: () {});
    await press(tester, LogicalKeyboardKey.f1);
    expect(find.text('اختصارات لوحة المفاتيح'), findsOneWidget);
    expect(find.text('Ctrl+S'), findsOneWidget);
    expect(find.text('Ctrl+Enter'), findsOneWidget);
  });

  testWidgets('a list: Ctrl+F puts the cursor in the search, F5 loads again', (
    tester,
  ) async {
    final search = FocusNode();
    addTearDown(search.dispose);
    var loads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppListShortcuts(
          searchFocus: search,
          onRefresh: () => loads++,
          child: Scaffold(body: TextField(focusNode: search)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(search.hasFocus, isFalse);
    await press(tester, LogicalKeyboardKey.keyF, control: true);
    expect(search.hasFocus, isTrue);
    await press(tester, LogicalKeyboardKey.f5);
    expect(loads, 1);
  });
}
