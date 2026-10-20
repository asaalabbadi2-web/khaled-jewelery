import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/screens/add_voucher_screen.dart';
import 'package:frontend/screens/voucher_saved_screen.dart';

import 'support/fake_voucher_api.dart';
import 'support/payload_witness.dart';
import 'support/voucher_screen_harness.dart';

/// The voucher screen review, release 1 (the owner, 20 Oct 2026): what the
/// screen says is true, and what it sends is what was meant. What it sent
/// before is kept whole first (ADR-049 UI-2): a gold payment over an invoice
/// and a cash receipt -- this release changes neither.
void main() {
  setUpAll(loadCairo);
  final open = openVoucher;

  const goldInvoice = [
    {
      'invoice_id': 11,
      'invoice_number': 'PI-0011',
      'date': '2026-09-01T00:00:00',
      'open_main_karat': 40.0,
    },
  ];
  const goldPlan = {
    'cash': [],
    'gold': [
      {'invoice_id': 11, 'karat': 21, 'weight': 10.0},
    ],
    'cash_on_account': 0.0,
    'gold_on_account_main_karat': 0.0,
    'invoices': [
      {
        'invoice_id': 11,
        'invoice_number': 'PI-0011',
        'date': '2026-09-01T00:00:00',
      },
    ],
  };

  group('what it sends is what it sent (ADR-049)', () {
    testWidgets('a gold payment over an invoice', (tester) async {
      final api = await open(
        tester,
        api: FakeVoucherApi(openGold: goldInvoice, plan: goldPlan),
      );
      await toGold(tester);
      await grams(tester, '10');
      await tester.tap(find.byKey(const Key('invoice-pick-11')));
      await tester.pumpAndSettle();
      await save(tester);
      expectPayload('voucher_payment_gold_invoice', api.created.single);
    });

    testWidgets('a cash receipt from a customer', (tester) async {
      final api = await open(tester, voucherType: 'receipt', supplierId: null);
      await tester.tap(find.text('اضغط للبحث والاختيار').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('عميل الصاغة').last);
      await tester.pumpAndSettle();
      await pickSafe(tester, 'الصندوق');
      await tester.enterText(cashAmount(), '750');
      await tester.pumpAndSettle();
      await save(tester);
      expectPayload('voucher_receipt_cash', api.created.single);
    });
  });

  testWidgets('a saved gold voucher edited unchanged sends its own lines, its '
      'party line stored on the weight twin not taken for a line of its own', (
    tester,
  ) async {
    final api = await open(
      tester,
      existing: {
        'id': 77,
        'voucher_type': 'payment',
        'status': 'pending',
        'date': '2026-10-01T00:00:00',
        'party_type': 'supplier',
        'supplier_id': 5,
        'description': 'سداد ذهب',
        'account_lines': [
          {
            'account_id': 80,
            'line_type': 'credit',
            'amount_type': 'gold',
            'amount': 10.0,
            'karat': 21.0,
          },
          {
            'account_id': 51,
            'line_type': 'debit',
            'amount_type': 'gold',
            'amount': 10.0,
            'karat': 21.0,
          },
        ],
      },
    );
    await save(tester);
    final lines = [
      for (final l in api.updated.single['account_lines'] as List)
        '${l['line_type']} ${l['account_id']} ${l['amount']}',
    ];
    expect(lines, ['credit 80 10.0', 'debit 50 10.0']);
  });

  group('the invoices\' fill', () {
    const cashInvoice = [
      {
        'invoice_id': 12,
        'invoice_number': 'PI-0012',
        'date': '2026-09-02T00:00:00',
        'open_cash': 800.0,
        'open_main_karat': 40.0,
      },
    ];

    testWidgets('is not offered to a gold payment, and the grams stay', (
      tester,
    ) async {
      await open(tester, api: FakeVoucherApi(openCash: cashInvoice));
      await toGold(tester);
      await grams(tester, '10');
      await tester.tap(find.byKey(const Key('invoice-pick-12')));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('fill-from-invoices')), findsNothing);
      expect(find.text('جاهز للحفظ'), findsOneWidget);
    });
  });

  group('it says what is true', () {
    const hint = 'الأكثر استخداماً';

    testWidgets('no safe filled, none said to be', (tester) async {
      await open(tester, api: FakeVoucherApi(), voucherType: 'receipt',
          supplierId: null);
      final picker = find.text('اختر حساب/خزينة');
      if (picker.evaluate().isNotEmpty) {
        expect(find.textContaining(hint), findsNothing);
      }
    });

    testWidgets('a safe picked by hand is not said to be filled', (
      tester,
    ) async {
      await open(tester);
      await pickSafe(tester, 'الصندوق');
      expect(find.textContaining(hint), findsNothing);
    });

    testWidgets('one line is «سطر واحد», and an empty voucher is not '
        'said balanced', (tester) async {
      await open(tester);
      expect(find.text('سطر واحد'), findsOneWidget);
      expect(find.text('1 سطور'), findsNothing);
      expect(find.text('السند متوازن'), findsNothing);
    });

    testWidgets('a party with its own account is not said to be posted on '
        'the aggregate', (tester) async {
      await open(tester);
      expect(find.textContaining('الحساب التجميعي'), findsNothing);
    });

    testWidgets('an amount and its currency are apart', (tester) async {
      await open(tester);
      await pickSafe(tester, 'الصندوق');
      await tester.enterText(cashAmount(), '500');
      await tester.pumpAndSettle();
      expect(said('500.00 ر.س'), findsWidgets);
      expect(said('500.00ر.س'), findsNothing);
    });
  });

  testWidgets('opened for a supplier with the party named, the supplier stays '
      'chosen', (tester) async {
    await open(tester, partyType: 'supplier');
    expect(find.text('مورد الذهب'), findsWidgets);
    expect(find.textContaining('اختر الطرف'), findsNothing);
    expect(find.textContaining('غير جاهز للحفظ — اختر حساب السطر 1'),
        findsOneWidget);
  });

  group('saved, it says so with its number (the owner, 20 Oct 2026)', () {
    Future<FakeVoucherApi> saved(WidgetTester tester) async {
      final api = await open(tester);
      await pickSafe(tester, 'الصندوق');
      await tester.enterText(cashAmount(), '500');
      await tester.pumpAndSettle();
      await save(tester);
      return api;
    }

    testWidgets('the number, its state and what it was', (tester) async {
      await saved(tester);
      expect(find.byType(AddVoucherScreen), findsNothing);
      expect(find.byType(VoucherSavedScreen), findsOneWidget);
      expect(find.textContaining('PV-2026-00901'), findsOneWidget);
      expect(find.text('مُعتمد'), findsOneWidget);
      expect(find.textContaining('مورد الذهب'), findsWidgets);
      expect(said('500.00 ر.س'), findsWidgets);
      expect(find.byKey(const Key('voucher-saved-open')), findsOneWidget);
    });

    testWidgets('«سند جديد» opens an empty voucher of the same kind', (
      tester,
    ) async {
      await saved(tester);
      await tester.tap(find.byKey(const Key('voucher-saved-new')));
      await tester.pumpAndSettle();
      expect(find.byType(AddVoucherScreen), findsOneWidget);
      expect(find.text('سند صرف'), findsWidgets);
      expect(find.textContaining('غير جاهز للحفظ'), findsOneWidget);
    });

    testWidgets('«رجوع» returns to where it was opened from', (tester) async {
      await saved(tester);
      await tester.tap(find.byKey(const Key('voucher-saved-back')));
      await tester.pumpAndSettle();
      expect(find.byType(VoucherSavedScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });
  });
}
