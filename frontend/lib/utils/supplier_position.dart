// Where we stand with a supplier, said in words (PURCHASE-UX-3).
//
// The server reports a supplier's balance as debit minus credit
// (services/live_balances.py, routes/suppliers.py statement): a credit -- a
// negative figure -- is what we owe him; a debit is what he owes us. A bare
// signed number on the screen read «-1,500» and left the reader to guess.

const double _cashTolerance = 0.005;
const double _goldTolerance = 0.0005;

String supplierCashPosition(
  double balance, {
  required String Function(double) formatCash,
}) {
  if (balance.abs() < _cashTolerance) return 'لا شيء نقدًا';
  final amount = formatCash(balance.abs());
  return balance < 0 ? 'علينا له $amount (دائن)' : 'لنا عنده $amount (مدين)';
}

String supplierGoldPosition(double grams, {required int mainKarat}) {
  if (grams.abs() < _goldTolerance) return 'لا شيء ذهبًا';
  final weight = '${grams.abs().toStringAsFixed(3)} جم عيار $mainKarat';
  return grams < 0 ? 'علينا له $weight (دائن)' : 'لنا عنده $weight (مدين)';
}

/// What saving this invoice does to what we owe the supplier: a purchase adds
/// to it, a supplier return takes from it.
String supplierCashEffect(
  double amount, {
  required bool isReturn,
  required String Function(double) formatCash,
}) {
  final value = formatCash(amount.abs());
  return isReturn
      ? 'سينقص ما علينا للمورد نقدًا بـ $value'
      : 'سيزيد ما علينا للمورد نقدًا بـ $value';
}

String supplierGoldEffect(
  double grams, {
  required bool isReturn,
  required int mainKarat,
}) {
  final value = '${grams.abs().toStringAsFixed(3)} جم عيار $mainKarat';
  return isReturn
      ? 'سينقص ما علينا للمورد ذهبًا بـ $value'
      : 'سيزيد ما علينا للمورد ذهبًا بـ $value';
}
