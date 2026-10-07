import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/purchase_readiness.dart';

/// PURCHASE-UX-1: the purchase screen says «ready» only when the server would
/// take the invoice, and otherwise names the first reason and where it is.
/// Each rule mirrors a refusal in backend/routes/invoices.py add_invoice, or
/// the domain rule the client holds stricter (cash obligation, Phase 13).
void main() {
  String cash(double v) => v.toStringAsFixed(2);

  PurchaseReadiness check(PurchaseReadinessFacts f) =>
      purchaseReadiness(f, formatCash: cash);

  const item = PurchaseItemFacts(weight: 12.5);

  PurchaseReadinessFacts base({
    bool branchChosen = true,
    bool supplierChosen = true,
    bool goldPriceKnown = true,
    List<PurchaseItemFacts> items = const [item],
    bool editsHeldWeightLines = false,
    PurchaseSettlement settlement = PurchaseSettlement.credit,
    double cashDue = 998.95,
    double cashPaid = 0,
    bool paymentMethodsAvailable = true,
    bool paymentMethodChosen = true,
    bool allowPartialPayments = true,
    List<PurchaseGoldLineFacts> goldLines = const [],
    bool goldSafesAvailable = true,
    int? forcedGoldSafeId,
    bool autoPostInvoices = true,
  }) => PurchaseReadinessFacts(
    branchChosen: branchChosen,
    supplierChosen: supplierChosen,
    goldPriceKnown: goldPriceKnown,
    items: items,
    editsHeldWeightLines: editsHeldWeightLines,
    settlement: settlement,
    cashDue: cashDue,
    cashPaid: cashPaid,
    paymentMethodsAvailable: paymentMethodsAvailable,
    paymentMethodChosen: paymentMethodChosen,
    allowPartialPayments: allowPartialPayments,
    goldLines: goldLines,
    goldSafesAvailable: goldSafesAvailable,
    forcedGoldSafeId: forcedGoldSafeId,
    autoPostInvoices: autoPostInvoices,
  );

  test('a complete credit purchase is ready', () {
    expect(check(base()).isReady, isTrue);
  });

  test('an edited invoice holding weights without items is not saved here', () {
    // An edit replaces the invoice with what the screen sends; the screen
    // has no manual weights, so it would drop them (an office reservation's
    // purchase is written with weight lines only).
    final r = check(base(editsHeldWeightLines: true));
    expect(r.isReady, isFalse);
    expect(
      r.message,
      'في هذه الفاتورة أوزان بلا أصناف لا تعرضها هذه الشاشة، فلا تُعدَّل منها',
    );
  });

  group('who and where', () {
    test('no branch: names the branch', () {
      final r = check(base(branchChosen: false));
      expect(r.isReady, isFalse);
      expect(r.target, PurchaseReadinessTarget.branch);
      expect(r.message, 'اختر الفرع');
    });

    test('no supplier: names the supplier', () {
      final r = check(base(supplierChosen: false));
      expect(r.target, PurchaseReadinessTarget.supplier);
      expect(r.message, 'اختر المورد');
    });
  });

  group('what was bought', () {
    test('nothing entered is empty, not an error', () {
      final r = check(base(items: const []));
      expect(r.kind, PurchaseReadinessKind.empty);
      expect(r.target, PurchaseReadinessTarget.item);
    });

    test('an item without weight names the item', () {
      final r = check(base(items: const [item, PurchaseItemFacts(weight: 0)]));
      expect(r.target, PurchaseReadinessTarget.item);
      expect(r.index, 1);
      expect(r.message, 'أدخل وزن الصنف 2');
    });

    test('a return heavier than the original line is refused', () {
      // return_weight_exceeds_original
      final r = check(
        base(items: const [PurchaseItemFacts(weight: 5.2, maxWeight: 5)]),
      );
      expect(r.target, PurchaseReadinessTarget.item);
      expect(
        r.message,
        'وزن الصنف 1 أكبر من وزنه في الفاتورة الأصلية (5.000 جم)',
      );
    });

    test('without a gold price it is not ready', () {
      final r = check(base(goldPriceKnown: false));
      expect(r.target, PurchaseReadinessTarget.goldPrice);
      expect(r.message, 'سعر الذهب لم يُحمَّل؛ حدّثه قبل الحفظ');
    });
  });

  group('cash', () {
    test('paying more cash than is owed is refused', () {
      final r = check(
        base(settlement: PurchaseSettlement.partial, cashPaid: 1000),
      );
      expect(r.target, PurchaseReadinessTarget.cashPaid);
      expect(r.message, 'المدفوع نقدًا أكبر من النقد المستحق (998.95)');
    });

    test('paying cash needs a payment method', () {
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          cashPaid: 500,
          paymentMethodChosen: false,
        ),
      );
      expect(r.target, PurchaseReadinessTarget.paymentMethod);
      expect(r.message, 'اختر وسيلة الدفع');
    });

    test('part of the cash needs partial payments allowed', () {
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          cashPaid: 500,
          allowPartialPayments: false,
        ),
      );
      expect(r.target, PurchaseReadinessTarget.cashPaid);
      expect(
        r.message,
        'الدفع النقدي الجزئي غير مفعّل في الإعدادات؛ ادفع 998.95 كاملًا أو اجعلها آجلة',
      );
    });

    test('all of the cash is fine with partial payments off', () {
      expect(
        check(
          base(
            settlement: PurchaseSettlement.partial,
            cashPaid: 998.95,
            allowPartialPayments: false,
          ),
        ).isReady,
        isTrue,
      );
    });

    test('cash typed under credit is not sent, so it does not block', () {
      expect(
        check(base(cashPaid: 5000, paymentMethodChosen: false)).isReady,
        isTrue,
      );
    });
  });

  group('gold settlement', () {
    const line21 = PurchaseGoldLineFacts(safeId: 5, karat: 21, weight: 20);

    test('barter needs gold', () {
      final r = check(base(settlement: PurchaseSettlement.barter));
      expect(r.target, PurchaseReadinessTarget.goldLine);
      expect(r.message, 'أضف سداد ذهب');
    });

    test('a barter with a gold line is ready', () {
      expect(
        check(
          base(settlement: PurchaseSettlement.barter, goldLines: [line21]),
        ).isReady,
        isTrue,
      );
    });

    test('a gold line without a safe names the line', () {
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          goldLines: const [
            line21,
            PurchaseGoldLineFacts(safeId: null, karat: 21, weight: 3),
          ],
        ),
      );
      expect(r.target, PurchaseReadinessTarget.goldLine);
      expect(r.index, 1);
      expect(r.message, 'اختر خزينة الذهب لسطر السداد 2');
    });

    test('a gold line without weight names the line', () {
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          goldLines: const [
            PurchaseGoldLineFacts(safeId: 5, karat: 21, weight: 0),
          ],
        ),
      );
      expect(r.message, 'أدخل وزن سطر السداد 1');
    });

    test('an empty gold line is ignored, as the payload ignores it', () {
      expect(
        check(
          base(
            settlement: PurchaseSettlement.partial,
            goldLines: const [
              PurchaseGoldLineFacts(safeId: null, karat: 21, weight: 0),
            ],
          ),
        ).isReady,
        isTrue,
      );
    });

    test('a safe fixed to another karat is refused', () {
      // karat_mismatch_for_safe_box
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          goldLines: const [
            PurchaseGoldLineFacts(
              safeId: 5,
              karat: 18,
              weight: 4,
              safeFixedKarat: 21,
            ),
          ],
        ),
      );
      expect(r.message, 'خزينة سطر السداد 1 لعيار 21 فقط');
    });

    test('with employee gold safes on, only the employee safe is taken', () {
      // gold_settlement_forced_employee_safe
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          goldLines: [line21],
          forcedGoldSafeId: 9,
        ),
      );
      expect(r.target, PurchaseReadinessTarget.goldLine);
      expect(r.message, 'سداد الذهب على خزينة ذهب الموظف فقط (سطر السداد 1)');
    });

    test('no gold safe at all is not ready', () {
      final r = check(
        base(
          settlement: PurchaseSettlement.barter,
          goldLines: [line21],
          goldSafesAvailable: false,
        ),
      );
      expect(r.message, 'لا توجد خزائن ذهب متاحة');
    });

    test('an unposted invoice takes no gold settlement', () {
      // unposted_no_gold_settlement
      final r = check(
        base(
          settlement: PurchaseSettlement.partial,
          goldLines: [line21],
          autoPostInvoices: false,
        ),
      );
      expect(
        r.message,
        'الترحيل التلقائي معطّل، والفاتورة غير المرحّلة لا تقبل سداد ذهب؛ أزل سداد الذهب',
      );
    });

    test('gold lines left under credit are not sent, so they do not block', () {
      expect(
        check(
          base(
            goldLines: const [
              PurchaseGoldLineFacts(safeId: null, karat: 21, weight: 3),
            ],
          ),
        ).isReady,
        isTrue,
      );
    });
  });
}
