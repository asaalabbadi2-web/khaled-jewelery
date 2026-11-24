// COMMISSION-3: a payment's commission is its method's rate and its fixed
// amount a transaction -- the server's numbers on the same case
// (backend/tests/test_payment_commission_is_whole.py: تابي, 1,000 -> 71.40).
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/payment_fee.dart';

void main() {
  final tabby = {'commission_rate': 6.99, 'commission_fixed_amount': 1.5};

  test('the rate and the fixed amount, as the server takes them', () {
    final fee = PaymentFee.of(tabby, 1000, vatRate: 0.15);
    expect(fee.commission, 71.40);
    expect(fee.vat, 10.71);
    expect(fee.net, 917.89);
  });

  test('nothing paid, nothing deducted', () {
    expect(PaymentFee.of(tabby, 0, vatRate: 0.15).commission, 0.0);
    expect(PaymentFee.of({'commission_rate': 0}, 500, vatRate: 0.15).net, 500.0);
  });

  test('the label says both', () {
    expect(PaymentFee.label(6.99, 1.5), '6.99% + 1.5');
    expect(PaymentFee.label(0.8, 0), '0.8%');
    expect(PaymentFee.label(0, 2), '2');
  });

  // ADR-100: a method's plans, half up to the halala -- the bank's numbers
  // (backend/tests/test_bnpl_fee_matches_the_bank.py).
  final tamara = {
    'commission_rate': 6.078,
    'commission_fixed_amount': 1.5,
    'plans': [
      {'installments': 4, 'commission_rate': 6.99},
      {'installments': 6, 'commission_rate': 5.99},
    ],
  };

  test('half up, as the bank: 2,850 at 6.99% and 1.50 is 200.72, its VAT 30.11', () {
    final fee = PaymentFee.of(tamara, 2850, vatRate: 0.15, installments: 4);
    expect(fee.commission, 200.72);
    expect(fee.vat, 30.11);
    expect(fee.net, 2619.17);
  });

  test('the plan named takes its rate; none named, the method\'s', () {
    expect(PaymentFee.of(tamara, 1000, vatRate: 0.15, installments: 6).commission, 61.40);
    expect(PaymentFee.of(tamara, 1000, vatRate: 0.15, installments: 4).rate, 6.99);
    expect(PaymentFee.of(tamara, 1000, vatRate: 0.15).rate, 6.078);
  });

  test('a method with plans says their range', () {
    expect(PaymentFee.plansOf(tamara), {4: 6.99, 6: 5.99});
    expect(PaymentFee.methodLabel(tamara), '5.99–6.99% + 1.5');
    expect(PaymentFee.methodLabel(tabby), '6.99% + 1.5');
  });

  // A company that rounds half to even and splits a refundable part of its
  // rate -- set on the method, no company named (the server's case:
  // test_its_report_line_by_line).
  final split = {
    'commission_rate': 6.99,
    'commission_fixed_amount': 1.5,
    'commission_rounding': 'half_even',
    'commission_refundable_rate': 4.99,
  };

  test('its two parts and their VAT, each rounded half to even', () {
    final a = PaymentFee.of(split, 2150, vatRate: 0.15);
    expect((a.commission, a.vat), (151.78, 22.76));
    final b = PaymentFee.of(split, 25000, vatRate: 0.15);
    expect((b.commission, b.vat), (1749.00, 262.34));
  });

  test('half up unless set: the same order, one part', () {
    final c = PaymentFee.of({...split, 'commission_rounding': null, 'commission_refundable_rate': 0}, 2150,
        vatRate: 0.15);
    expect((c.commission, c.vat), (151.79, 22.77));
  });
}
