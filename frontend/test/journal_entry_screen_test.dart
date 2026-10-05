import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/journal_entry_form.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_journal_api.dart';

/// JE-UX-2: the journal entry screen as a table (the owner, 5 Oct 2026).
/// Green means the server will take the entry; anything else names the reason
/// and the line, and the save does not go out.
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Map<String, dynamic> entry(List<Map<String, dynamic>> lines) => {
    'id': 7,
    'description': 'تسوية',
    'date': '2026-10-05',
    'entry_type': 'عادي',
    'lines': lines,
  };

  /// Opens the screen on a [width] wide window; returns what it pops with.
  Future<Future<Object?>> open(
    WidgetTester tester, {
    required FakeJournalApi api,
    Map<String, dynamic>? existing,
    double width = 1400,
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = Size(width, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    late Future<Object?> result;
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: Builder(
              builder: (context) => Scaffold(
                body: Center(
                  child: ElevatedButton(
                    onPressed: () => result = Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => Directionality(
                          textDirection: TextDirection.rtl,
                          child: AddEditJournalEntryScreen(
                            entry: existing,
                            isEditMode: existing != null,
                            apiService: api,
                          ),
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
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return result;
  }

  Finder rich(String text) => find.textContaining(text, findRichText: true);

  testWidgets('balanced and complete is ready, and saves', (tester) async {
    final api = FakeJournalApi();
    await open(
      tester,
      api: api,
      existing: entry([
        {'account_id': 11, 'cash_credit': 3000},
        {'account_id': 12, 'cash_debit': 3000},
      ]),
    );

    expect(find.text('جاهز للحفظ'), findsOneWidget);
    await tester.tap(find.text('حفظ القيد'));
    await tester.pumpAndSettle();

    expect(api.updated, hasLength(1));
    expect(api.updated.single['lines'], hasLength(2));
  });

  testWidgets('balanced, with a valued line missing its account, is not ready, '
      'names the line, and does not save', (tester) async {
    final api = FakeJournalApi();
    await open(
      tester,
      api: api,
      existing: entry([
        {'account_id': 11, 'cash_credit': 3000},
        {'account_id': 12, 'cash_debit': 1500},
        {'cash_debit': 1500},
      ]),
    );

    expect(find.text('جاهز للحفظ'), findsNothing);
    expect(find.text('غير جاهز للحفظ — اختر حساباً للسطر 3'), findsOneWidget);

    await tester.tap(find.text('حفظ القيد'));
    await tester.pumpAndSettle();
    expect(api.updated, isEmpty);
    expect(find.text('اختر حساباً لهذا السطر'), findsOneWidget);
  });

  testWidgets('a second save while the first is out is not sent', (
    tester,
  ) async {
    final api = FakeJournalApi()..hold = Completer<void>();
    await open(
      tester,
      api: api,
      existing: entry([
        {'account_id': 11, 'cash_credit': 3000},
        {'account_id': 12, 'cash_debit': 3000},
      ]),
    );

    await tester.tap(find.text('حفظ القيد'));
    await tester.pump();
    expect(find.text('جارٍ الحفظ…'), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();

    api.hold!.complete();
    await tester.pumpAndSettle();
    expect(api.updated, hasLength(1));
  });

  testWidgets('Ctrl+S saves a ready entry', (tester) async {
    final api = FakeJournalApi();
    await open(
      tester,
      api: api,
      existing: entry([
        {'account_id': 11, 'cash_credit': 3000},
        {'account_id': 12, 'cash_debit': 3000},
      ]),
    );

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(api.updated, hasLength(1));
  });

  testWidgets('a cash difference of 1,500.00 is shown as 1,500.00', (
    tester,
  ) async {
    await open(
      tester,
      api: FakeJournalApi(),
      existing: entry([
        {'account_id': 11, 'cash_credit': 1000},
        {'account_id': 12, 'cash_debit': 2500},
      ]),
    );
    expect(
      find.text('غير جاهز للحفظ — النقد غير متوازن: الفرق 1,500.00'),
      findsOneWidget,
    );
    expect(rich('1,500.00'), findsWidgets);
  });

  testWidgets('a new entry starts with empty amounts, not 0.0', (tester) async {
    await open(tester, api: FakeJournalApi());
    expect(find.text('0.0'), findsNothing);
    expect(find.text('أدخل مبالغ القيد'), findsOneWidget);
  });

  testWidgets('save and new stays, starts over, and leaving reports the save', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'yasargold_journal_entry_complete_later': jsonEncode({
        'date': '2026-10-05',
        'description': 'قيد أول',
        'entry_type': 'عادي',
        'lines': [
          {
            'account_id': 11,
            'cash_credit': '3000',
            'enabled_karats': [21],
          },
          {
            'account_id': 12,
            'cash_debit': '3000',
            'enabled_karats': [21],
          },
        ],
      }),
    });
    final api = FakeJournalApi();
    final result = await open(tester, api: api);
    await tester.tap(find.text('استعادة'));
    await tester.pumpAndSettle();
    expect(find.text('جاهز للحفظ'), findsOneWidget);

    await tester.tap(find.text('حفظ وجديد'));
    await tester.pumpAndSettle();
    expect(api.added, hasLength(1));
    expect(find.text('إضافة قيد يومية'), findsOneWidget);
    expect(find.text('قيد أول'), findsNothing);
    expect(find.text('أدخل مبالغ القيد'), findsOneWidget);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(await result, isTrue);
  });

  testWidgets(
    'a line in two karats shows the base-karat sum and its breakdown',
    (tester) async {
      await open(
        tester,
        api: FakeJournalApi(),
        existing: entry([
          {'account_id': 13, 'debit_21k': 8, 'debit_24k': 2.1875},
          {'account_id': 13, 'credit_21k': 10.5},
        ]),
      );
      expect(find.text('ذهب (غ · عيار 21)'), findsOneWidget);
      expect(find.text('10.5000'), findsOneWidget); // line 1, read-only sum
      expect(find.textContaining('2.5000'), findsOneWidget); // 24k in base karat
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    },
  );

  testWidgets('balance gold by the remainder fills the short side', (
    tester,
  ) async {
    await open(
      tester,
      api: FakeJournalApi(),
      existing: entry([
        {'account_id': 13, 'debit_21k': 10.5},
        {'account_id': 13},
      ]),
    );
    await tester.tap(find.byTooltip('خيارات السطر').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('وازن الذهب بالباقي'));
    await tester.pumpAndSettle();

    expect(find.text('10.5000'), findsOneWidget);
    expect(find.text('جاهز للحفظ'), findsOneWidget);
  });

  testWidgets('tablet portrait folds gold into the breakdown', (tester) async {
    await open(
      tester,
      api: FakeJournalApi(),
      width: 800,
      existing: entry([
        {'account_id': 13, 'debit_21k': 10.5},
        {'account_id': 13, 'credit_21k': 10.5},
      ]),
    );
    expect(find.text('ذهب (غ · عيار 21)'), findsNothing);
    expect(find.text('إضافة عيار:'), findsNWidgets(2));
    expect(find.text('جاهز للحفظ'), findsOneWidget);
  });

  testWidgets('a phone lays the lines out without overflowing', (tester) async {
    await open(
      tester,
      api: FakeJournalApi(),
      width: 390,
      existing: entry([
        {'account_id': 13, 'debit_21k': 10.5},
        {'account_id': 11, 'cash_credit': 3000},
        {'account_id': 12, 'cash_debit': 3000},
        {'account_id': 13, 'credit_21k': 10.5},
      ]),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('جاهز للحفظ'), findsOneWidget);
  });

  testWidgets('the dark theme renders the table', (tester) async {
    await open(
      tester,
      api: FakeJournalApi(),
      theme: DarkTheme.theme,
      existing: entry([
        {'account_id': 13, 'debit_21k': 8, 'debit_24k': 2.1875},
        {'account_id': 13, 'credit_21k': 10.5},
      ]),
    );
    expect(tester.takeException(), isNull);
    expect(find.text('جاهز للحفظ'), findsOneWidget);
  });
}
