import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_voucher_api.dart';
import 'support/payload_witness.dart';
import 'support/voucher_screen_harness.dart';

/// A payment on a period expense (ADR-090 law 2; the owner, 14 Nov 2026): a
/// payment to «آخر» on an expense account with a period expense open offers
/// it, folded, so an ordinary expense is not weighed down; chosen, the
/// party's cash line names it, and the server puts the payment where the
/// expense's balance stands. The expenses are asked only when an account is
/// chosen, not on opening the screen.
void main() {
  setUpAll(loadCairo);

  const rent = {
    'id': 7, 'description': 'إيجار المعرض 2026', 'expense_account_id': 92, 'status': 'active',
    'amount': 144900.0, 'remaining_to_pay': 72450.0,
  };
  const paidOff = {
    'id': 8, 'description': 'رخصة 2026', 'expense_account_id': 92, 'status': 'active',
    'amount': 1200.0, 'remaining_to_pay': 0.0,
  };

  Future<FakeVoucherApi> openOn(WidgetTester tester, int account, {String voucherType = 'payment'}) =>
      openVoucher(
        tester,
        api: FakeVoucherApi(periodExpenses: const [rent, paidOff]),
        voucherType: voucherType,
        supplierId: null,
        partyType: 'other',
        otherAccountId: account,
      );

  testWidgets('an expense account with one open offers it, folded', (tester) async {
    await openOn(tester, 92);
    expect(find.byKey(const Key('period-expense-link')), findsOneWidget);
    expect(find.byKey(const Key('period-expense-picker')), findsNothing);       // folded
    await tester.ensureVisible(find.byKey(const Key('period-expense-link')));
    await tester.tap(find.text('مصروف فترة (اختياري)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-expense-picker')));
    await tester.pumpAndSettle();
    // the one left to pay; the paid one is not offered
    expect(find.textContaining('إيجار المعرض 2026 — الباقي 72,450.00'), findsWidgets);
    expect(find.textContaining('رخصة 2026'), findsNothing);
  });

  testWidgets('an account with none, or a receipt, offers nothing', (tester) async {
    await openOn(tester, 91);
    expect(find.byKey(const Key('period-expense-link')), findsNothing);
  });

  testWidgets('a voucher opened with no account chosen asks nothing', (tester) async {
    final api = await openVoucher(tester, api: FakeVoucherApi(periodExpenses: const [rent]));
    expect(api.periodExpensesAsked, 0);
    expect(find.byKey(const Key('period-expense-link')), findsNothing);
  });

  testWidgets('what it sends: the party cash line names the expense it pays', (tester) async {
    final api = await openOn(tester, 92);
    await pickSafe(tester, 'الصندوق');
    await tester.enterText(cashAmount(), '72450');
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('period-expense-link')));
    await tester.tap(find.text('مصروف فترة (اختياري)'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('period-expense-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('إيجار المعرض 2026 — الباقي').last);
    await tester.pumpAndSettle();
    await save(tester);
    final lines = (api.created.single['account_lines'] as List).cast<Map>();
    final party = lines.singleWhere((l) => l['account_id'] == 92);
    expect(party['period_expense_id'], 7);
    expect(lines.where((l) => l['account_id'] != 92).every((l) => !l.containsKey('period_expense_id')), isTrue);
    expectPayload('voucher_period_expense', api.created.single);
  });

  testWidgets('not chosen, the expense is paid as before', (tester) async {
    final api = await openOn(tester, 92);
    await pickSafe(tester, 'الصندوق');
    await tester.enterText(cashAmount(), '500');
    await tester.pumpAndSettle();
    await save(tester);
    final lines = (api.created.single['account_lines'] as List).cast<Map>();
    expect(lines.every((l) => !l.containsKey('period_expense_id')), isTrue);
  });
}
