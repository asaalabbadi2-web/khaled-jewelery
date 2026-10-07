import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/sales_readiness.dart';

/// SALES-UX-2: the sales screen says «ready» only when the server would take
/// the sale, and otherwise names the first reason and where it is. Each rule
/// mirrors a refusal in backend/routes/invoices.py add_invoice (or the screen's
/// own: a line at no weight, a karat the shop does not sell).
void main() {
  String cash(double v) => v.toStringAsFixed(2);

  SalesReadiness check(SalesReadinessFacts f) =>
      salesReadiness(f, formatCash: cash);

  const line = SalesLineFacts(weight: 10, karat: 21);

  SalesReadinessFacts base({
    bool branchChosen = true,
    List<SalesLineFacts> lines = const [line],
    double total = 1000,
    double paid = 1000,
    double barter = 0,
    bool partialAllowed = false,
    bool namedCustomer = false,
    bool goldPriceKnown = true,
    bool paymentMethodMissing = false,
  }) => SalesReadinessFacts(
    branchChosen: branchChosen,
    lines: lines,
    total: total,
    paid: paid,
    barter: barter,
    partialAllowed: partialAllowed,
    namedCustomer: namedCustomer,
    goldPriceKnown: goldPriceKnown,
  );

  test('a sale paid in full is ready, to the cash customer', () {
    expect(check(base()).isReady, isTrue);
  });

  test('no lines: empty, not an error', () {
    final r = check(base(lines: const []));
    expect(r.kind, SalesReadinessKind.empty);
    expect(r.target, SalesReadinessTarget.items);
  });

  test('no branch names the branch', () {
    final r = check(base(branchChosen: false));
    expect(r.target, SalesReadinessTarget.branch);
    expect(r.message, 'اختر الفرع');
  });

  test('a line without weight names the line', () {
    final r = check(
      base(lines: const [line, SalesLineFacts(weight: 0, karat: 21)]),
    );
    expect(r.target, SalesReadinessTarget.items);
    expect(r.index, 1);
    expect(r.message, 'أدخل وزن السطر 2');
  });

  test('a karat the shop does not sell is refused', () {
    final r = check(base(lines: const [SalesLineFacts(weight: 3, karat: 25)]));
    expect(r.message, 'عيار السطر 1 يجب أن يكون 18 أو 21 أو 22 أو 24');
  });

  test('payments above the total are refused', () {
    final r = check(base(paid: 1200));
    expect(r.target, SalesReadinessTarget.payment);
    expect(r.message, 'مجموع الدفعات أكبر من إجمالي الفاتورة');
  });

  test('barter above the total is refused', () {
    final r = check(base(paid: 0, barter: 1500));
    expect(r.message, 'قيمة المقايضة أكبر من إجمالي الفاتورة');
  });

  test('something owed with partial payments off says what remains', () {
    final r = check(base(paid: 400));
    expect(r.target, SalesReadinessTarget.payment);
    expect(r.message, 'أكمل الدفع: يتبقى 600.00');
  });

  test('barter counts as paid', () {
    expect(check(base(paid: 400, barter: 600)).isReady, isTrue);
  });

  test('a credit sale to the cash customer is refused', () {
    // credit_needs_customer
    final r = check(base(paid: 400, partialAllowed: true));
    expect(r.target, SalesReadinessTarget.customer);
    expect(r.message, 'البيع الآجل يحتاج عميلًا مسمّى، يتبقى 600.00');
  });

  test('a credit sale to a named customer is ready', () {
    expect(
      check(base(paid: 0, partialAllowed: true, namedCustomer: true)).isReady,
      isTrue,
    );
  });

  test('without a gold price it is not ready', () {
    final r = check(base(goldPriceKnown: false));
    expect(r.target, SalesReadinessTarget.goldPrice);
    expect(r.message, 'سعر الذهب لم يُحمَّل؛ حدّثه قبل الحفظ');
  });

  test('a cent of difference is paid', () {
    expect(check(base(paid: 999.995)).isReady, isTrue);
  });

  test('a sale at no price is not ready', () {
    final r = check(base(total: 0, paid: 0));
    expect(r.message, 'إجمالي الفاتورة صفر؛ حدّد سعر السطر');
  });

  group('price warnings (the seller sees the market, never the cost)', () {
    List<String> warn(double net) => salesPriceWarnings(
      lines: const [SalesLineFacts(weight: 10, karat: 21)],
      net: net,
      goldPrice24k: 480,
      formatCash: cash,
    );

    // 10 g of 21k at a 24k price of 480: 4,200.00 of metal.
    test('under the metal at market is a sale under cost', () {
      expect(warn(1000).single, contains('تحت التكلفة'));
    });
    test('a price far above the market is flagged', () {
      expect(warn(100000).single, contains('أعلى بكثير من سعر السوق'));
    });
    test('wages on the metal are not flagged', () {
      expect(warn(4300), isEmpty);
      expect(warn(5500), isEmpty); // 31 % over the metal: wages
    });
    test('without a gold price there is nothing to compare', () {
      expect(
        salesPriceWarnings(
          lines: const [SalesLineFacts(weight: 10, karat: 21)],
          net: 1,
          goldPrice24k: 0,
          formatCash: cash,
        ),
        isEmpty,
      );
    });
  });
}
