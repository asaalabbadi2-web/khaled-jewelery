import 'bidi.dart';
import 'currency_utils.dart';

/// What is between us and a customer or supplier, as the ledger says it --
/// the balance the server sends with each (`balance_cash`,
/// `balance_gold_<k>k`), debit less credit: more than nothing is «لنا عنده»,
/// less is «علينا له». One phrase for cash and one for each karat held;
/// none when nothing stands; null when the party came without its balance.
///
/// The one wording, read by the voucher screen and the party picker alike.
List<String>? partyBalanceSaid(
  Map<String, dynamic> party, {
  required String currencySymbol,
}) {
  if (!party.containsKey('balance_cash')) return null;
  double read(String key) => (party[key] as num?)?.toDouble() ?? 0.0;
  String side(double v) => v > 0 ? 'لنا عنده' : 'علينا له';
  final cash = read('balance_cash');
  return [
    if (cash.abs() >= 0.005)
      '${side(cash)} ${ltrIsolate(formatAmount(cash.abs()))} $currencySymbol',
    for (final k in const [24, 22, 21, 18])
      if (read('balance_gold_${k}k').abs() >= 0.0005)
        '${side(read('balance_gold_${k}k'))} '
            '${ltrIsolate(formatGrams(read('balance_gold_${k}k').abs()))} جم عيار $k',
  ];
}
