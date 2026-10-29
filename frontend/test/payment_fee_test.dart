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
}
