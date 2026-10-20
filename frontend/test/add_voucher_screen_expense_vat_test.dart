import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_voucher_api.dart';
import 'support/payload_witness.dart';
import 'support/voucher_screen_harness.dart';

/// An expense paid with a tax invoice carries its VAT (the owner, 20 Oct
/// 2026): offered on an operating expense; the VAT suggested at the rate from
/// what is paid, until it is typed; not ready without the invoice -- the
/// supplier's name and VAT number, the invoice's number. The server splits it
/// off the expense and names its account (services/expense_vat.py).
void main() {
  setUpAll(loadCairo);

  const groups = {
    'account_groups': {
      'operating_expenses': {
        'account_id': 94,
        'subtree_ids': [94, 91, 92],
      },
    },
  };

  /// A payment to «آخر» on [account]: 92 «كهرباء» is an operating expense,
  /// 93 a purchase.
  Future<FakeVoucherApi> openOn(WidgetTester tester, int account) => openVoucher(
    tester,
    api: FakeVoucherApi(appConfig: groups),
    supplierId: null,
    partyType: 'other',
    otherAccountId: account,
  );

  Finder field(String key) => find.descendant(
    of: find.byKey(Key(key)),
    matching: find.byType(EditableText),
  );

  String vatShown(WidgetTester tester) =>
      tester.widget<EditableText>(field('expense-vat-amount')).controller.text;

  Future<void> paid(WidgetTester tester, String amount) async {
    await tester.enterText(cashAmount(), amount);
    await tester.pumpAndSettle();
  }

  Future<void> turnOn(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const Key('expense-vat-on')));
    await tester.tap(find.byKey(const Key('expense-vat-on')));
    await tester.pumpAndSettle();
  }

  Future<void> invoice(WidgetTester tester) async {
    await tester.enterText(field('expense-vat-supplier'), 'شركة الكهرباء');
    await tester.enterText(field('expense-vat-tax-number'), '300000000000003');
    await tester.enterText(field('expense-vat-invoice'), 'F-1009');
    await tester.pumpAndSettle();
  }

  testWidgets('an operating expense offers its tax invoice', (tester) async {
    await openOn(tester, 92);
    expect(find.byKey(const Key('expense-vat')), findsOneWidget);
  });

  testWidgets('a purchase does not', (tester) async {
    await openOn(tester, 93);
    expect(find.byKey(const Key('expense-vat')), findsNothing);
  });

  testWidgets('the VAT is suggested at the rate from what is paid, until it is '
      'typed', (tester) async {
    await openOn(tester, 92);
    await pickSafe(tester, 'الصندوق');
    await paid(tester, '115');
    await turnOn(tester);
    expect(vatShown(tester), '15.00');

    await paid(tester, '230');
    expect(vatShown(tester), '30.00');

    await tester.enterText(field('expense-vat-amount'), '12');
    await tester.pumpAndSettle();
    await paid(tester, '345');
    expect(vatShown(tester), '12');
  });

  testWidgets('not ready without its tax invoice', (tester) async {
    await openOn(tester, 92);
    await pickSafe(tester, 'الصندوق');
    await paid(tester, '115');
    await turnOn(tester);
    expect(find.textContaining('غير جاهز للحفظ — أدخل اسم مورد الفاتورة'), findsOneWidget);
    await invoice(tester);
    expect(find.text('جاهز للحفظ'), findsOneWidget);
  });

  testWidgets('the sentence says the VAT in it', (tester) async {
    await openOn(tester, 92);
    await pickSafe(tester, 'الصندوق');
    await paid(tester, '115');
    await turnOn(tester);
    final summary = tester.widget<Text>(find.byKey(const Key('voucher-summary')));
    expect(
      summary.data!.replaceAll(RegExp('[\\u2066-\\u2069]'), ''),
      contains('منها ضريبة 15.00 ر.س'),
    );
  });

  testWidgets('what it sends: the expense whole, and its tax invoice', (
    tester,
  ) async {
    final api = await openOn(tester, 92);
    await pickSafe(tester, 'الصندوق');
    await paid(tester, '115');
    await turnOn(tester);
    await invoice(tester);
    await save(tester);
    expectPayload('voucher_expense_vat', api.created.single);
    // The page that says it was saved says its VAT too.
    expect(said('منها ضريبة'), findsOneWidget);
  });
}
