import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/app_leave_guard.dart';

/// UI-6 (ADR-049): a filled form asks before it is thrown away; an untouched
/// one, or one just saved, leaves at once.
void main() {
  late TextEditingController name;

  Future<void> openForm(WidgetTester tester, {String opened = ''}) async {
    name = TextEditingController(text: opened);
    addTearDown(name.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => AppLeaveGuard(
                    controllers: [name],
                    child: Scaffold(
                      body: Column(
                        children: [
                          TextField(controller: name),
                          TextButton(
                            onPressed: () => Navigator.of(context).pop(true),
                            child: const Text('saved'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('cancel'),
                          ),
                        ],
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

  bool formIsOpen() => find.byType(TextField).evaluate().isNotEmpty;

  testWidgets('untouched, it leaves at once', (tester) async {
    await openForm(tester, opened: 'مؤسسة الأمل');
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    expect(formIsOpen(), isFalse);
  });

  testWidgets('filled, it asks; «البقاء» keeps the form, and what was typed', (
    tester,
  ) async {
    await openForm(tester);
    await tester.enterText(find.byType(TextField), 'عميل جديد');
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    expect(find.text('الخروج دون حفظ؟'), findsOneWidget);

    await tester.tap(find.text('البقاء'));
    await tester.pumpAndSettle();
    expect(formIsOpen(), isTrue);
    expect(name.text, 'عميل جديد');
  });

  testWidgets('filled, «الخروج دون حفظ» leaves', (tester) async {
    await openForm(tester);
    await tester.enterText(find.byType(TextField), 'عميل جديد');
    await tester.tap(find.text('cancel'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(formIsOpen(), isFalse);
  });

  testWidgets('saved, it leaves without asking', (tester) async {
    await openForm(tester);
    await tester.enterText(find.byType(TextField), 'عميل جديد');
    await tester.tap(find.text('saved'));
    await tester.pumpAndSettle();
    expect(find.text('الخروج دون حفظ؟'), findsNothing);
    expect(formIsOpen(), isFalse);
  });
}
