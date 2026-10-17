import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/clearing_settlement_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/theme/app_theme.dart';

import 'support/dark_text.dart';
import 'support/fake_clearing_api.dart';
import 'support/shots.dart';

/// CLEARING-SEL-1: a settlement settles the payments chosen for it.
///
/// Production, 6 Oct 2026: from the clearing monitor the owner settled Mada
/// payment 3526 (330.00, SELL-2026-1596), then 3527 (90.00). The settlement
/// screen sent every pending payment of the box instead of the selection, the
/// server settled them oldest-first, and both amounts landed on 3520 (3,050.00,
/// SELL-2026-1593): the screen then showed 2,630 + 330 + 90 for what was one
/// payment of 3,050 left. (AV-2026-00472 / 00473.)
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FakeClearingApi> open(
    WidgetTester tester, {
    List<int>? selected,
    double? due,
    ThemeData? theme,
    Size size = const Size(1200, 2400),
    bool overAPage = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeClearingApi();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: MaterialApp(
          theme: theme,
          home: overAPage
              ? Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ClearingSettlementScreen(
                              initialClearingSafeBoxId: 32,
                              initialBankSafeBoxId: 37,
                              initialDueAmount: due,
                              initialInvoicePaymentIds: selected,
                              initialTxCount: selected?.length,
                              apiService: api,
                            ),
                          ),
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                )
              : ClearingSettlementScreen(
                  initialClearingSafeBoxId: 32,
                  initialBankSafeBoxId: 37,
                  initialDueAmount: due,
                  initialInvoicePaymentIds: selected,
                  initialTxCount: selected?.length,
                  apiService: api,
                ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    if (overAPage) {
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }
    return api;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.ensureVisible(find.text('تنفيذ التسوية'));
    await tester.tap(find.text('تنفيذ التسوية'));
    await tester.pumpAndSettle();
    if (find.text('تأكيد الحفظ').evaluate().isNotEmpty) {
      await tester.tap(find.text('تأكيد الحفظ'));
      // The save button spins while the success dialog waits for «حسناً».
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('حسناً').evaluate().isNotEmpty) {
        await tester.tap(find.text('حسناً'));
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
  }

  testWidgets('a payment chosen in the monitor is the one settled', (
    tester,
  ) async {
    final api = await open(tester, selected: [3526], due: 330);
    await settle(tester);

    expect(api.settlements, hasLength(1));
    expect(api.settlements.single.ids, [3526]);
    expect(api.settlements.single.gross, 330);
  });

  testWidgets('the cap is what was chosen, not the whole box', (tester) async {
    final api = await open(tester, selected: [3527], due: 90);
    await tester.enterText(find.byKey(const ValueKey('clearing.gross')), '500');
    await settle(tester);

    expect(api.settlements, isEmpty);
  });

  testWidgets('the chosen payments are shown before settling', (tester) async {
    await open(tester, selected: [3526], due: 330);
    expect(find.textContaining('SELL-2026-1596'), findsOneWidget);
    expect(find.textContaining('SELL-2026-1593'), findsNothing);
  });

  testWidgets(
    'opened without a choice, it settles the box oldest-first and says so',
    (tester) async {
      final api = await open(tester);
      expect(find.textContaining('أقدم الدفعات'), findsOneWidget);
      await settle(tester);

      expect(api.settlements, hasLength(1));
      expect(api.settlements.single.ids, [3520, 3526, 3527]);
    },
  );

  // ADR-050: the journal shown before saving is the server's.
  testWidgets('the journal shown before saving is the one the server builds', (
    tester,
  ) async {
    final api = await open(tester);
    await tester.ensureVisible(find.text('تنفيذ التسوية'));
    await tester.tap(find.text('تنفيذ التسوية'));
    await tester.pumpAndSettle();

    expect(api.previews, [3470]);
    final journal = find.byKey(const Key('clearing-journal-preview'));
    for (final l in FakeClearingApi.previewLines) {
      expect(
        find.descendant(
          of: journal,
          matching: find.text('${l['account_number']} - ${l['account_name']}'),
        ),
        findsOneWidget,
      );
    }
    expect(find.textContaining('vat_receivable'), findsNothing);
    expect(
      api.settlements,
      isEmpty,
      reason: 'nothing saved before «تأكيد الحفظ»',
    );
  });

  testWidgets('a preview the server refuses saves nothing and says why', (
    tester,
  ) async {
    final api = await open(tester);
    api.refusePreview =
        '{"error": "no_due_amount", "message": "لا يوجد مبلغ مستحق للتسوية في هذه الخزينة"}';
    await tester.ensureVisible(find.text('تنفيذ التسوية'));
    await tester.tap(find.text('تنفيذ التسوية'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('clearing-journal-preview')), findsNothing);
    expect(
      find.text('لا يوجد مبلغ مستحق للتسوية في هذه الخزينة'),
      findsOneWidget,
    );
    expect(api.settlements, isEmpty);
  });

  // خ٣ (ADR-050): the settlement reads in the dark theme -- its summary,
  // tiles and buttons were written in light colours.
  for (final (name, size) in [
    ('desktop', const Size(1440, 2200)),
    ('tablet', tabletSize),
  ]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await open(tester, theme: DarkTheme.theme, size: size);
      expect(tester.takeException(), isNull);
      await shot(tester, 'clearing_settlement_dark_$name');
      expectNoTextVanishesOnDark(tester);
      expectNoLightSurfaceOnDark(tester);
    });
  }

  // خ٤ (ADR-050): Ctrl+S, and a form that asks before what the employee
  // typed is lost -- not what the screen filled in itself as it loaded.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
  }) async {
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus is! FocusScopeNode) focus.unfocus();
    await tester.pump();
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+S asks the server for the journal, as the button does', (
    tester,
  ) async {
    final api = await open(tester);
    await press(tester, LogicalKeyboardKey.keyS, control: true);
    expect(api.previews, hasLength(1));
    expect(find.byKey(const Key('clearing-journal-preview')), findsOneWidget);
  });

  testWidgets('opened and left at once, it does not ask -- what it filled '
      'itself is not lost typing', (tester) async {
    await open(tester, selected: [3526], due: 330, overAPage: true);
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('الخروج دون حفظ؟'), findsNothing);
    expect(find.byType(ClearingSettlementScreen), findsNothing);
  });

  testWidgets('a reference typed, Esc asks first', (tester) async {
    await open(tester, overAPage: true);
    await tester.enterText(
      find.widgetWithText(TextField, 'رقم مرجعي (اختياري)'),
      'BANK-123',
    );
    await press(tester, LogicalKeyboardKey.escape);
    expect(find.text('الخروج دون حفظ؟'), findsOneWidget);
  });
}
