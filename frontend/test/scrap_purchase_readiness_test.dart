import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/scrap_purchase_readiness.dart';

/// SALES-UX-9: the scrap purchase screen says «ready» only when it would be
/// saved, and otherwise names the first reason and where it is. The rules are
/// the screen's own (it refused them one by one, at save) and the server's:
/// the scrap purchase is paid in full, and a customer who is not the walk-in
/// one has their identity on file.
void main() {
  String cash(double v) => v.toStringAsFixed(2);

  ScrapPurchaseReadiness check(ScrapPurchaseFacts f) =>
      scrapPurchaseReadiness(f, formatCash: cash);

  const line = ScrapLineFacts(
    standing: 10,
    stones: 0,
    weight: 10,
    karat: 21,
    total: 4000,
  );

  ScrapPurchaseFacts base({
    bool branchChosen = true,
    List<ScrapLineFacts> lines = const [line],
    double total = 4000,
    double paid = 4000,
    String? customerMissingIdentity,
    bool goldPriceKnown = true,
  }) => ScrapPurchaseFacts(
    branchChosen: branchChosen,
    lines: lines,
    total: total,
    paid: paid,
    customerMissingIdentity: customerMissingIdentity,
    goldPriceKnown: goldPriceKnown,
  );

  test('a purchase paid in full is ready', () {
    expect(check(base()).isReady, isTrue);
  });

  test('no lines: empty, not an error', () {
    final r = check(base(lines: const []));
    expect(r.kind, ScrapPurchaseReadinessKind.empty);
    expect(r.target, ScrapPurchaseTarget.items);
  });

  test('no branch names the branch', () {
    final r = check(base(branchChosen: false));
    expect(r.target, ScrapPurchaseTarget.branch);
    expect(r.message, 'اختر الفرع');
  });

  test('a line with neither weight nor an amount names the line', () {
    final r = check(
      base(
        lines: const [
          line,
          ScrapLineFacts(standing: 0, stones: 0, weight: 0, karat: 21, total: 0),
        ],
      ),
    );
    expect(r.target, ScrapPurchaseTarget.items);
    expect(r.index, 1);
    expect(r.message, 'أدخل وزن السطر 2 أو مبلغه');
  });

  test('a weighed line needs its standing weight', () {
    final r = check(
      base(
        lines: const [
          ScrapLineFacts(standing: 0, stones: 0, weight: 5, karat: 21, total: 2000),
        ],
      ),
    );
    expect(r.message, 'أدخل الوزن القائم للسطر 1');
  });

  test('stones heavier than the piece are refused', () {
    final r = check(
      base(
        lines: const [
          ScrapLineFacts(standing: 5, stones: 6, weight: -1, karat: 21, total: 2000),
        ],
      ),
    );
    expect(r.message, 'وزن أحجار السطر 1 أكبر من وزنه القائم');
  });

  test('a net weight of nothing is refused', () {
    final r = check(
      base(
        lines: const [
          ScrapLineFacts(standing: 5, stones: 5, weight: 0, karat: 21, total: 0),
        ],
      ),
    );
    expect(r.message, 'أدخل وزن السطر 1 أو مبلغه');
  });

  test('an amount-only line is taken without weights', () {
    final r = check(
      base(
        lines: const [
          ScrapLineFacts(standing: 0, stones: 0, weight: 0, karat: 21, total: 1500),
        ],
        total: 1500,
        paid: 1500,
      ),
    );
    expect(r.isReady, isTrue);
  });

  test('a karat the shop does not buy is refused', () {
    final r = check(
      base(
        lines: const [
          ScrapLineFacts(standing: 5, stones: 0, weight: 5, karat: 25, total: 2000),
        ],
      ),
    );
    expect(r.message, 'عيار السطر 1 يجب أن يكون 18 أو 21 أو 22 أو 24');
  });

  test('a customer without identity on file is named', () {
    final r = check(base(customerMissingIdentity: 'مؤسسة الأمل'));
    expect(r.target, ScrapPurchaseTarget.customer);
    expect(
      r.message,
      'العميل «مؤسسة الأمل» بلا رقم هوية أو نسختها أو تاريخ ميلاد',
    );
  });

  test('the purchase is paid in full, and says what remains', () {
    final r = check(base(paid: 1000));
    expect(r.target, ScrapPurchaseTarget.payment);
    expect(r.message, 'أكمل الدفع: يتبقى 3000.00');
  });

  test('more paid than the total is refused', () {
    final r = check(base(paid: 4500));
    expect(r.message, 'مجموع الدفعات أكبر من إجمالي الفاتورة');
  });

  test('nothing to pay for is refused', () {
    final r = check(base(total: 0, paid: 0));
    expect(r.message, 'إجمالي الفاتورة صفر؛ حدّد المبلغ أو الوزن');
  });

  test('without a live gold price it is not ready', () {
    final r = check(base(goldPriceKnown: false));
    expect(r.target, ScrapPurchaseTarget.goldPrice);
  });

  group('price warnings (what is paid against the live gold price)', () {
    List<String> warn(double paid, {double karat = 21, double w = 10}) =>
        scrapPurchasePriceWarnings(
          lines: [
            ScrapLineFacts(
              standing: w,
              stones: 0,
              weight: w,
              karat: karat,
              total: paid,
            ),
          ],
          goldPrice24k: 480,
          formatCash: cash,
        );

    // 10 g of 21k at a 24k price of 480: 4,200.00 live.
    test('above the live price is held for the manager', () {
      expect(warn(4500).single, contains('يُحجز لاعتماد المدير'));
    });
    test('at or under the live price is not flagged', () {
      expect(warn(4200), isEmpty);
      expect(warn(3900), isEmpty);
    });
    test('far under it is a probable typing mistake', () {
      expect(warn(400).single, contains('أقل بكثير'));
    });
    test('an amount-only line weighs nothing, so nothing to compare', () {
      expect(warn(500, w: 0), isEmpty);
    });
  });
}
