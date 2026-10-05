import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/journal_entry_form.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_journal_api.dart';

/// JE-UX-1: leaving the entry screen with typed work asks first; leaving it
/// untouched does not. Back used to drop a half-typed entry without a word.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> openForm(WidgetTester tester) async {
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AddEditJournalEntryScreen(
                        apiService: FakeJournalApi(),
                      ),
                    ),
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
  }

  testWidgets('an untouched form closes without asking', (tester) async {
    await openForm(tester);
    expect(find.text('إضافة قيد يومية'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.text('قيد غير محفوظ'), findsNothing);
    expect(find.text('إضافة قيد يومية'), findsNothing);
  });

  testWidgets('a typed description is asked about, and kept on stay', (
    tester,
  ) async {
    await openForm(tester);
    await tester.enterText(find.byType(TextFormField).first, 'دفعة مورد');

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('قيد غير محفوظ'), findsOneWidget);

    await tester.tap(find.text('متابعة التحرير'));
    await tester.pumpAndSettle();
    expect(find.text('إضافة قيد يومية'), findsOneWidget);
    expect(find.text('دفعة مورد'), findsOneWidget);
  });

  testWidgets('discard leaves, and later keeps the draft', (tester) async {
    await openForm(tester);
    await tester.enterText(find.byType(TextFormField).first, 'دفعة مورد');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('تجاهل التعديلات'));
    await tester.pumpAndSettle();
    expect(find.text('إضافة قيد يومية'), findsNothing);

    await openForm(tester);
    await tester.enterText(find.byType(TextFormField).first, 'قيد للإكمال');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('إكمال لاحقاً').last);
    await tester.pumpAndSettle();
    expect(find.text('إضافة قيد يومية'), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('yasargold_journal_entry_complete_later'),
      contains('قيد للإكمال'),
    );
  });
}
