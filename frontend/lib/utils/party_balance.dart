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

/// The same, short, for a list a party is picked from (the owner, 20 Oct
/// 2026: «يكفي أن يذكر إجمالي رصيده محولًا إلى العيار الرئيسي»): the cash,
/// and the gold of every karat as one figure in [mainKarat].
List<String>? partyBalanceBrief(
  Map<String, dynamic> party, {
  required String currencySymbol,
  required int mainKarat,
}) {
  if (!party.containsKey('balance_cash')) return null;
  double read(String key) => (party[key] as num?)?.toDouble() ?? 0.0;
  String side(double v) => v > 0 ? 'لنا عنده' : 'علينا له';
  final cash = read('balance_cash');
  final gold = goldInMainKarat(
    {for (final k in const [24, 22, 21, 18]) k: read('balance_gold_${k}k')},
    mainKarat,
  );
  return [
    if (cash.abs() >= 0.005)
      '${side(cash)} ${ltrIsolate(formatAmount(cash.abs()))} $currencySymbol',
    if (gold.abs() >= 0.0005)
      '${side(gold)} ${ltrIsolate(formatGrams(gold.abs()))} جم بالعيار $mainKarat',
  ];
}

/// Weights by karat as one weight of [mainKarat] -- the settings' karat,
/// never a fixed one (the owner, 20 Oct 2026): each by its fineness.
double goldInMainKarat(Map<int, double> byKarat, int mainKarat) =>
    byKarat.entries.fold(0.0, (sum, e) => sum + e.value * e.key / mainKarat);
