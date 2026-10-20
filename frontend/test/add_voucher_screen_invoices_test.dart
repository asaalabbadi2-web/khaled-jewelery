import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_voucher_api.dart';
import 'support/voucher_screen_harness.dart';

/// A supplier payment's invoices come after its amount (the owner, 20 Oct
/// 2026: «قائمة فواتير المورد يجب أن تكون تحت سطور السند حتى تقرأ القيم، ولا
/// تقبل نسب فواتير يتجاوز المبلغ المصروف رصيدها»): under the lines; waiting
/// for an amount; the others locked once the payment is used up; one it no
/// longer reaches said, and the voucher not ready -- the server refuses it
/// (invoice_gets_nothing).
void main() {
  setUpAll(loadCairo);

  const invoices = [
    {
      'invoice_id': 11,
      'invoice_number': 'PI-0011',
      'date': '2026-09-01T00:00:00',
      'open_cash': 700.0,
    },
    {
      'invoice_id': 12,
      'invoice_number': 'PI-0012',
      'date': '2026-09-02T00:00:00',
      'open_cash': 800.0,
    },
  ];

  Map<String, dynamic> plan({double left = 0, List<int> unreached = const []}) => {
    'cash': [
      {'invoice_id': 11, 'amount': 700.0},
    ],
    'gold': [],
    'cash_on_account': left,
    'gold_on_account_main_karat': 0.0,
    'unreached': unreached,
    'invoices': [
      for (final i in invoices)
        {'invoice_id': i['invoice_id'], 'invoice_number': i['invoice_number'], 'date': i['date']},
    ],
  };

  Future<void> amount(WidgetTester tester, String typed) async {
    await tester.enterText(cashAmount(), typed);
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, int id) async {
    await tester.ensureVisible(find.byKey(Key('invoice-pick-$id')));
    await tester.tap(find.byKey(Key('invoice-pick-$id')));
    await tester.pumpAndSettle();
  }

  bool enabled(WidgetTester tester, int id) =>
      tester.widget<CheckboxListTile>(find.byKey(Key('invoice-pick-$id'))).onChanged != null;

  testWidgets('the invoices come under the lines', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(openCash: invoices));
    final lines = tester.getRect(find.byKey(const Key('voucher-line-account-0')));
    final list = tester.getRect(find.byKey(const Key('invoice-count')));
    expect(list.top, greaterThan(lines.bottom));
    final party = tester.getRect(find.byKey(const Key('voucher-party-card')));
    expect(list.left, greaterThan(party.right),
        reason: 'in the lines\' column, not under the party');
  });

  testWidgets('before an amount, they wait for it', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(openCash: invoices));
    expect(find.text('أدخل المبلغ أولًا، ثم اختر ما يسدده'), findsOneWidget);
    expect(enabled(tester, 11), isFalse);

    await pickSafe(tester, 'الصندوق');
    await amount(tester, '700');
    expect(enabled(tester, 11), isTrue);
  });

  testWidgets('once the payment is used up, the others are locked', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(openCash: invoices, plan: plan()));
    await pickSafe(tester, 'الصندوق');
    await amount(tester, '700');
    await choose(tester, 11);
    expect(enabled(tester, 12), isFalse);
    expect(find.textContaining('الدفعة لا تكفي لها'), findsOneWidget);
    expect(enabled(tester, 11), isTrue, reason: 'a chosen one can be let go');
  });

  testWidgets('one the payment no longer reaches is said, and the voucher '
      'is not ready', (tester) async {
    await openVoucher(
      tester,
      api: FakeVoucherApi(openCash: invoices, plan: plan(left: 100, unreached: [12])),
    );
    await pickSafe(tester, 'الصندوق');
    await amount(tester, '700');
    await choose(tester, 11);
    await choose(tester, 12);
    expect(find.textContaining('لا تصل إليها الدفعة — ألغِ اختيارها'), findsOneWidget);
    expect(
      find.textContaining('غير جاهز للحفظ — ألغِ اختيار فاتورة لا تصل إليها الدفعة'),
      findsOneWidget,
    );
  });

  testWidgets('the amount is not filled from the invoices: it comes first', (
    tester,
  ) async {
    await openVoucher(tester, api: FakeVoucherApi(openCash: invoices, plan: plan()));
    await pickSafe(tester, 'الصندوق');
    await amount(tester, '700');
    await choose(tester, 11);
    expect(find.byKey(const Key('fill-from-invoices')), findsNothing);
  });
}
