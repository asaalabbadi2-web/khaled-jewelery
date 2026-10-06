import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/supplier_position.dart';

/// PURCHASE-UX-3: the purchase review said a supplier's balance as a signed
/// number, and «سيزداد رصيد المورد» while the number fell -- and the same on
/// a return, which takes from what we owe. Said in words now.
void main() {
  String cash(double v) => v.toStringAsFixed(2);

  test('a credit balance is what we owe him', () {
    expect(
      supplierCashPosition(-1500, formatCash: cash),
      'علينا له 1500.00 (دائن)',
    );
    expect(
      supplierGoldPosition(-58.771, mainKarat: 21),
      'علينا له 58.771 جم عيار 21 (دائن)',
    );
  });

  test('a debit balance is what he owes us', () {
    expect(
      supplierCashPosition(250, formatCash: cash),
      'لنا عنده 250.00 (مدين)',
    );
    expect(
      supplierGoldPosition(3.2, mainKarat: 21),
      'لنا عنده 3.200 جم عيار 21 (مدين)',
    );
  });

  test('nothing is nothing', () {
    expect(supplierCashPosition(0.001, formatCash: cash), 'لا شيء نقدًا');
    expect(supplierGoldPosition(0.0001, mainKarat: 21), 'لا شيء ذهبًا');
  });

  test('a purchase adds to what we owe, a return takes from it', () {
    expect(
      supplierCashEffect(998.95, isReturn: false, formatCash: cash),
      'سيزيد ما علينا للمورد نقدًا بـ 998.95',
    );
    expect(
      supplierCashEffect(998.95, isReturn: true, formatCash: cash),
      'سينقص ما علينا للمورد نقدًا بـ 998.95',
    );
    expect(
      supplierGoldEffect(58.771, isReturn: true, mainKarat: 21),
      'سينقص ما علينا للمورد ذهبًا بـ 58.771 جم عيار 21',
    );
  });
}
