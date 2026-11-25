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
    Map<String, dynamic>? method,
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
    if (method != null) api.method = method;
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

  // ADR-100 (the owner, 24 Nov 2026): «في تمارا تم وضع الخطط لكن في شاشة
  // تسوية المقاصة لا زالت تظهر النسبة القديمة». A method with plans, computed
  // order by order, or with a fee a deposit is charged by the server -- each
  // payment by its plan -- and the screen shows and sends that, no rate field.
  final tamara = {
    'id': 13, 'name': 'تمارا', 'default_safe_box_id': 32, 'settlement_bank_safe_box_id': 37,
    'commission_rate': 6.078, 'commission_fixed_amount': 1.5, 'commission_per_order': true,
    'fee_expense_account_id': 845,
    'plans': [
      {'installments': 4, 'commission_rate': 6.99},
      {'installments': 6, 'commission_rate': 5.99},
    ],
  };

  testWidgets('a method with plans: the server\'s charge, not one rate', (tester) async {
    final api = await open(tester, method: tamara);
    expect(api.charges, isNotEmpty, reason: 'the server was asked');
    expect(find.byKey(const ValueKey('clearing.server_charge')), findsOneWidget);
    expect(find.byKey(const ValueKey('clearing.fee_rate')), findsNothing, reason: 'no single rate to show');
    expect(find.textContaining('6.078'), findsNothing);
    expect(find.textContaining('بنسبة خطتها'), findsOneWidget);
    await settle(tester);
    expect(api.settlements.single.fee, 219.19);
    expect(api.settlements.single.vat, 32.88);
  });

  // The owner, 25 Nov 2026: «في شاشة تسوية المقاصة هناك توضيح للخصم لكل وسيلة
  // هل يتبع آخر إصلاح؟» -- it said «نسبة 6.08%», the old single rate rounded.
  testWidgets('the method\'s card says its plans and terms, not one rate', (tester) async {
    await open(tester, method: {
      ...tamara,
      'deposit_fixed_fee': 6.0,
      'deposit_confirmation_required': true,
      'tax_invoice_from': '2026-10-01',
      'plans': [
        {'installments': 2, 'commission_rate': 6.99},
        {'installments': 3, 'commission_rate': 6.99},
        {'installments': 4, 'commission_rate': 6.99},
        {'installments': 6, 'commission_rate': 5.99},
        {'installments': 12, 'commission_rate': 5.99},
      ],
    });
    final card = find.byKey(const ValueKey('clearing.method_card'));
    expect(card, findsOneWidget);
    String said(String t) => t.replaceAll(RegExp('[\u2066-\u2069\u200e\u200f]'), '');
    final texts = tester.widgetList<Text>(find.descendant(of: card, matching: find.byType(Text)))
        .map((t) => said(t.data ?? '')).toList();
    expect(texts.where((t) => t.startsWith('نسبة')), isEmpty, reason: 'no single rate beside the plans');
    expect(texts, contains('2، 3، 4 دفعات: 6.99%'));
    expect(texts, contains('6، 12 دفعة: 5.99%'));
    expect(texts.any((t) => t.contains('1.5') && t.contains('لكل طلب')), isTrue);
    expect(texts.any((t) => t.contains('6') && t.contains('لكل إيداع')), isTrue);
    expect(texts, contains('يُؤكَّد الإيداع بما وصل البنك'));
    expect(texts, contains('الضريبة تنتظر فاتورة الشهر'));
  });

  testWidgets('a chosen payment is charged alone', (tester) async {
    final api = await open(tester, method: tamara, selected: [3526], due: 330);
    expect(api.charges.last, [3526]);
  });

  testWidgets('Mada, one rate on the total, as before: its rate shown, no VAT sent', (tester) async {
    final api = await open(tester, method: {
      'id': 10, 'name': 'مدى', 'default_safe_box_id': 32, 'settlement_bank_safe_box_id': 37,
      'commission_rate': 0.8, 'fee_expense_account_id': 845,
    });
    expect(api.charges, isEmpty);
    expect(find.byKey(const ValueKey('clearing.fee_rate')), findsOneWidget);
    final card = find.byKey(const ValueKey('clearing.method_card'));
    expect(find.descendant(of: card, matching: find.textContaining('نسبة')), findsOneWidget,
        reason: 'a method without plans: its one rate');
    expect(find.descendant(of: card, matching: find.textContaining('0.8%')), findsOneWidget);
    await settle(tester);
    expect(api.settlements.single.vat, isNull);
  });
}
