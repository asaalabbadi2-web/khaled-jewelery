import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/voucher_readiness.dart';

/// VOUCHER-UX-1, stage 2: what stands in the way of saving a voucher, the
/// first reason only, in the order the employee fills the screen.
void main() {
  const cash = VoucherLineFacts(hasAccount: true, isGold: false, amount: 500);
  VoucherFacts facts({
    String partyType = 'supplier',
    bool partyChosen = true,
    List<VoucherLineFacts> lines = const [cash],
    bool cashInvoiceMissing = false,
    bool cashExceedsInvoice = false,
    bool unbalanced = false,
  }) => VoucherFacts(
    partyType: partyType,
    partyChosen: partyChosen,
    lines: lines,
    cashInvoiceMissing: cashInvoiceMissing,
    cashExceedsInvoice: cashExceedsInvoice,
    unbalanced: unbalanced,
  );

  test('a voucher with its party, account and amount is ready', () {
    expect(voucherReadiness(facts()), isNull);
  });

  test('the party first, named for what it is', () {
    for (final (type, said) in [
      ('supplier', 'اختر المورد'),
      ('customer', 'اختر العميل'),
      ('employee', 'اختر الموظف'),
      ('other', 'اختر الحساب'),
    ]) {
      expect(
        voucherReadiness(
          facts(partyType: type, partyChosen: false, lines: const []),
        ),
        said,
      );
    }
  });

  test('then each line: its account, then its amount', () {
    expect(
      voucherReadiness(
        facts(
          lines: const [
            cash,
            VoucherLineFacts(hasAccount: false, isGold: false, amount: 0),
          ],
        ),
      ),
      'اختر حساب السطر 2',
    );
    expect(
      voucherReadiness(
        facts(
          lines: const [
            VoucherLineFacts(hasAccount: true, isGold: false, amount: 0),
          ],
        ),
      ),
      'أدخل مبلغ السطر 1',
    );
  });

  test('a gold line needs a weight, a karat, and a standing weight '
      'not under the net', () {
    VoucherFacts gold(VoucherGoldFacts entry) => facts(
      lines: [
        VoucherLineFacts(
          hasAccount: true,
          isGold: true,
          amount: 0,
          gold: [entry],
        ),
      ],
    );
    expect(
      voucherReadiness(gold(const VoucherGoldFacts(weight: 0, hasKarat: true))),
      'أدخل وزن السطر 1',
    );
    expect(
      voucherReadiness(
        gold(const VoucherGoldFacts(weight: 10, hasKarat: false)),
      ),
      'اختر عيار السطر 1',
    );
    expect(
      voucherReadiness(
        gold(
          const VoucherGoldFacts(
            weight: 10,
            hasKarat: true,
            gross: 9,
            stones: 0,
          ),
        ),
      ),
      'الوزن القائم في السطر 1 أقل من الصافي',
    );
    expect(
      voucherReadiness(gold(const VoucherGoldFacts(weight: 10, hasKarat: true))),
      isNull,
    );
  });

  test('lines that do not balance are said', () {
    expect(voucherReadiness(facts(unbalanced: true)), 'السطور غير متوازنة');
  });

  test('a payment declared for an invoice names it, and is within it', () {
    expect(
      voucherReadiness(facts(cashInvoiceMissing: true)),
      'اختر الفاتورة التي تخصها الدفعة',
    );
    expect(
      voucherReadiness(facts(cashExceedsInvoice: true)),
      'مبلغ السند أكبر من المتبقي على الفاتورة',
    );
  });
}
