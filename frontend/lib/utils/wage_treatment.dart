/// How manufacturing wages are treated (ADR-039), as the server says it.
///
/// inventory: a purchase capitalizes the wages on the wage inventory, and a
///            sale moves them to the wage expense.
/// expense:   a purchase charges them to the wage expense, and a sale leaves
///            the wage inventory alone.
const String kWageModeInventory = 'inventory';
const String kWageModeExpense = 'expense';

String wageModeLabel(String mode) => mode == kWageModeInventory
    ? 'رسملة في مخزون أجور المصنعية'
    : 'تحميل على المصروفات';

String wageModeExplanation(String mode) => mode == kWageModeInventory
    ? 'الشراء يُدخل الأجور في مخزون أجور المصنعية، والبيع ينقل أجرة القطعة المباعة إلى المصروفات.'
    : 'الشراء يحمّل الأجور على المصروفات مباشرة، والبيع لا يخصم شيئًا من مخزون أجور المصنعية.';

/// What changing the treatment leaves behind, and the entry that zeroes it:
/// to expense when the wage inventory is positive, to revenue when negative
/// (the owner, 6 Oct 2026). The screen advises; it posts nothing.
String wageModeChangeAdvice({
  required double balance,
  required String accountLabel,
  required String Function(double) formatCash,
}) {
  const tolerance = 0.005;
  if (balance.abs() < tolerance) {
    return 'رصيد $accountLabel صفر، فلا يلزم قيد.';
  }
  final amount = formatCash(balance.abs());
  if (balance > 0) {
    return 'في $accountLabel رصيد مدين $amount لن يُنقل إلى المصروفات بعد التغيير. '
        'صفّره بقيد يومية: مدين مصروف أجور المصنعية، دائن $accountLabel.';
  }
  return 'في $accountLabel رصيد دائن $amount. '
      'صفّره بقيد يومية: مدين $accountLabel، دائن حساب إيرادات.';
}
