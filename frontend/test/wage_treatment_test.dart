import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/wage_treatment.dart';

/// ADR-039: changing the wage treatment leaves the wage inventory's balance
/// unmatched; the settings screen says so, and names the entry that zeroes it
/// -- to expense when positive, to revenue when negative (the owner).
void main() {
  String cash(double v) => v.toStringAsFixed(2);
  const account = '1320 مخزون أجور المصنعية';

  test('a positive balance is zeroed to expense', () {
    expect(
      wageModeChangeAdvice(
        balance: 1250,
        accountLabel: account,
        formatCash: cash,
      ),
      'في $account رصيد مدين 1250.00 لن يُنقل إلى المصروفات بعد التغيير. '
      'صفّره بقيد يومية: مدين مصروف أجور المصنعية، دائن $account.',
    );
  });

  test('a negative balance is zeroed to revenue', () {
    expect(
      wageModeChangeAdvice(
        balance: -72960.02,
        accountLabel: account,
        formatCash: cash,
      ),
      'في $account رصيد دائن 72960.02. '
      'صفّره بقيد يومية: مدين $account، دائن حساب إيرادات.',
    );
  });

  test('a zero balance needs no entry', () {
    expect(
      wageModeChangeAdvice(
        balance: 0.001,
        accountLabel: account,
        formatCash: cash,
      ),
      'رصيد $account صفر، فلا يلزم قيد.',
    );
  });

  test('each treatment says what a purchase and a sale do', () {
    expect(wageModeLabel(kWageModeInventory), 'رسملة في مخزون أجور المصنعية');
    expect(wageModeLabel(kWageModeExpense), 'تحميل على المصروفات');
    expect(wageModeExplanation(kWageModeExpense), contains('لا يخصم شيئًا'));
  });
}
