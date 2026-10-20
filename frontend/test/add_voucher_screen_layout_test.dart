import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_voucher_api.dart';
import 'support/voucher_screen_harness.dart';

/// The voucher screen review, release 2 (the owner, 20 Oct 2026: «تأكد أن
/// تصميمها يلبي سهولة الاستخدام»): the screen asks in the order the employee
/// decides -- who, with their balance; cash or gold; from where; how much;
/// for which invoices -- says each thing once, and says the voucher in one
/// sentence beside its save.
void main() {
  setUpAll(loadCairo);

  /// A supplier who is owed cash and 21k, and owes us 24k (debit less credit).
  const owed = [
    {
      'id': 5,
      'name': 'مورد الذهب',
      'account_id': 50,
      'supplier_code': 'S-000005',
      'balance_cash': -7784.83,
      'balance_gold_18k': 0.0,
      'balance_gold_21k': -2748.71,
      'balance_gold_22k': 0.0,
      'balance_gold_24k': 2265.87,
    },
  ];

  Future<void> pickSafe(WidgetTester tester, String name) async {
    await tester.ensureVisible(find.text('اختر حساب/خزينة').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('اختر حساب/خزينة').first);
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining(name).last);
    await tester.pumpAndSettle();
  }

  Finder kind() => find.byKey(const Key('voucher-line-kind-0'));
  Finder account() => find.text('اختر حساب/خزينة').first;

  testWidgets('cash or gold is asked before where from, and choosing a safe '
      'does not move it', (tester) async {
    await openVoucher(tester);
    expect(tester.getCenter(kind()).dy, lessThan(tester.getCenter(account()).dy));

    final before = tester.getCenter(kind());
    await pickSafe(tester, 'الصندوق');
    expect(tester.getCenter(kind()), before, reason: 'the safe\'s balance '
        'used to be put above the choice, which then moved under the hand');
  });

  testWidgets('the party is said with what is between us', (tester) async {
    await openVoucher(tester, api: FakeVoucherApi(suppliers: owed));
    final balance = find.byKey(const Key('voucher-party-balance'));
    expect(balance, findsOneWidget);
    expect(said('علينا له 7,784.83 ر.س'), findsOneWidget);
    expect(said('علينا له 2,748.710 جم عيار 21'), findsOneWidget);
    expect(said('لنا عنده 2,265.870 جم عيار 24'), findsOneWidget);
  });

  testWidgets('each thing is said once, in the employee\'s words', (
    tester,
  ) async {
    await openVoucher(tester);
    expect(find.text('سند صرف'), findsOneWidget, reason: 'the title, once');
    expect(find.textContaining('مؤشرات السند'), findsNothing);
    expect(find.textContaining('المورد المختار'), findsNothing);
    expect(find.textContaining('سطر الطرف'), findsNothing);
    expect(find.textContaining('مجموع النقد'), findsNothing);
  });

  testWidgets('the voucher is said in one sentence beside its save', (
    tester,
  ) async {
    await openVoucher(tester);
    await pickSafe(tester, 'الصندوق');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first,
      '500',
    );
    await tester.pumpAndSettle();
    final summary = find.byKey(const Key('voucher-summary'));
    expect(summary, findsOneWidget);
    expect(
      tester.widget<Text>(summary).data!.replaceAll(RegExp('[\u2066-\u2069]'), ''),
      'تصرف 500.00 ر.س من الصندوق إلى مورد الذهب',
    );
  });

  testWidgets('what is written about the voucher waits folded', (tester) async {
    await openVoucher(tester);
    expect(find.byKey(const Key('voucher-details')), findsOneWidget);
    expect(
      find.widgetWithText(TextField, 'اسم المستلم').hitTestable(),
      findsNothing,
    );
  });

  testWidgets('every quick template can be seen and reached', (tester) async {
    await openVoucher(tester);
    for (final title in [
      'دفعة لمورد',
      'راتب موظف',
      'سلفة موظف',
      'مكافأة موظف',
      'مصروف تشغيلي',
    ]) {
      expect(find.text(title).hitTestable(), findsOneWidget, reason: title);
    }
  });

  testWidgets('two columns on a desktop, one on a phone, nothing overflows', (
    tester,
  ) async {
    await openVoucher(tester);
    final party = tester.getCenter(find.byKey(const Key('voucher-party-card')));
    expect((party.dx - tester.getCenter(kind()).dx).abs(), greaterThan(300));

    tester.view.physicalSize = const Size(390, 2400);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final p2 = tester.getCenter(find.byKey(const Key('voucher-party-card')));
    expect(tester.getCenter(kind()).dy, greaterThan(p2.dy));
  });

  testWidgets('on a phone the sentence is read over a save as wide as the '
      'screen, not squeezed a word to a line', (tester) async {
    await openVoucher(tester, size: const Size(390, 844));
    await pickSafe(tester, 'الصندوق');
    final amount = find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first;
    await tester.ensureVisible(amount);
    await tester.enterText(amount, '500');
    await tester.pumpAndSettle();
    final summary = tester.getRect(find.byKey(const Key('voucher-summary')));
    final save = tester.getRect(find.text('حفظ السند').last);
    expect(summary.bottom, lessThanOrEqualTo(save.top), reason: 'above it');
    expect(summary.height, lessThan(120), reason: 'two or three lines at most');
  });

  testWidgets('the expense template leaves the expense to the employee, and '
      'offers only expenses', (tester) async {
    final api = FakeVoucherApi(
      appConfig: const {
        'account_groups': {
          'expenses': {
            'id': 90,
            'subtree_ids': [90, 91, 92],
          },
        },
      },
    );
    await openVoucher(tester, api: api);
    await tester.tap(find.text('مصروف تشغيلي'));
    await tester.pumpAndSettle();
    expect(find.textContaining('خسارة الوزن'), findsNothing,
        reason: 'the first expense in the tree was chosen for them');

    await tester.tap(find.text('اختر حساب المصروف'));
    await tester.pumpAndSettle();
    expect(find.textContaining('كهرباء'), findsOneWidget);
    expect(find.textContaining('مورد الذهب'), findsNothing);
  });

  testWidgets('a safe\'s balance is said once, and its shortfall under the '
      'amount', (tester) async {
    await openVoucher(tester);
    await pickSafe(tester, 'الصندوق');
    final amount = find.widgetWithText(TextFormField, 'المبلغ (ريال) *').first;
    await tester.enterText(amount, '500');
    await tester.pumpAndSettle();
    expect(said('100,000.00'), findsOneWidget);
    expect(find.textContaining('لا يغطي'), findsNothing);

    await tester.enterText(amount, '150000');
    await tester.pumpAndSettle();
    expect(find.textContaining('لا يغطي'), findsOneWidget);
  });
}
