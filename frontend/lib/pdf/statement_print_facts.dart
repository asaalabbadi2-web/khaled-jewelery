/// What a printed account statement says of a balance (the owner, 28 Oct
/// 2026, on the statement's print).
library;

import 'package:intl/intl.dart';

/// A balance as a statement writes it: its size and whose it is -- «عليه»
/// when the account owes (a debit balance, above nothing), «له» when it is
/// owed (a credit balance, below it), and no word for nothing. A minus sign
/// said it before («بدلا من سالب يتم استبداله بله وعليه»). [decimals] is 3
/// for grams, 2 for riyals.
String statementBalance(double value, {required int decimals}) {
  final parts = statementBalanceParts(value, decimals: decimals);
  return parts.whose.isEmpty ? parts.size : '${parts.size} ${parts.whose}';
}

/// A balance's size and whose it is, apart -- for a cash balance, whose
/// currency stands between them (25,000.00 ⃁ عليه).
({String size, String whose}) statementBalanceParts(double value, {required int decimals}) {
  final format = NumberFormat(decimals == 3 ? '#,##0.000' : '#,##0.00', 'en');
  final size = format.format(value.abs());
  if (size == format.format(0)) return (size: size, whose: '');
  return (size: size, whose: value > 0 ? 'عليه' : 'له');
}

/// Whether a balance [statementBalance] wrote is owed to the account.
bool statementBalanceIsCredit(String written) => written.endsWith(' له');

/// The balance rows around the statement's lines: the opening balance
/// before the oldest line and the closing balance after the newest -- at the
/// top and the foot as the lines run («لو كان من الأحدث إلى الأقدم يكون
/// السطر هو الرصيد الختامي والعكس صحيح»; «يكون آخر سطر الرصيد الختامي
/// والعكس صحيح»).
typedef StatementBalanceRow = ({String label, double gold, double cash, DateTime? date});

({StatementBalanceRow first, StatementBalanceRow last}) statementEdgeRows({
  required bool newestFirst,
  required double openingGold,
  required double openingCash,
  required double closingGold,
  required double closingCash,
  DateTime? from,
  DateTime? to,
}) {
  final StatementBalanceRow opening = (label: 'رصيد افتتاحي', gold: openingGold, cash: openingCash, date: from);
  final StatementBalanceRow closing = (label: 'رصيد ختامي', gold: closingGold, cash: closingCash, date: to);
  return newestFirst ? (first: closing, last: opening) : (first: opening, last: closing);
}

/// The statement's period in words: «من» the first day «إلى» the last --
/// read right to left, the older date first. «2026-06-01 – 2026-10-28», with
/// no Arabic word, was set left to right, and read from the right it began
/// with the newer date (the owner, 29 Oct 2026). Null for every period.
String? statementPeriodText(DateTime? from, DateTime? to) {
  if (from == null || to == null) return null;
  final day = DateFormat('yyyy-MM-dd');
  return 'من ${day.format(from)} إلى ${day.format(to)}';
}

