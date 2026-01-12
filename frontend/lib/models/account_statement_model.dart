import 'package:flutter/foundation.dart';

class AccountStatement {
  final double openingBalanceGold;
  final double openingBalanceCash;
  final double closingBalanceGoldNormalized;
  final double closingBalanceCash;
  final Map<String, double> closingBalanceGoldDetails;
  final double? entityBalanceGoldNormalized;
  final double? entityBalanceCash;
  final Map<String, double> entityBalanceGoldDetails;
  final int mainKarat;
  final double totalDebitGold;
  final double totalCreditGold;
  final double totalDebitCash;
  final double totalCreditCash;
  final List<StatementLine> lines;

  AccountStatement({
    required this.openingBalanceGold,
    required this.openingBalanceCash,
    required this.closingBalanceGoldNormalized,
    required this.closingBalanceCash,
    required this.closingBalanceGoldDetails,
    required this.entityBalanceGoldNormalized,
    required this.entityBalanceCash,
    required this.entityBalanceGoldDetails,
    required this.mainKarat,
    required this.totalDebitGold,
    required this.totalCreditGold,
    required this.totalDebitCash,
    required this.totalCreditCash,
    required this.lines,
  });

  factory AccountStatement.fromJson(Map<String, dynamic> json) {
    var linesFromJson = json['lines'] as List? ?? [];
    List<StatementLine> statementLines = linesFromJson
        .map((i) => StatementLine.fromJson(i))
        .toList();

    double runningGold =
        json['opening_balance_gold_normalized']?.toDouble() ?? 0.0;
    double runningCash = json['opening_balance_cash']?.toDouble() ?? 0.0;

    final entityBalances = json['entity_balances'] as Map<String, dynamic>?;
    final entityBalanceGoldDetails =
        (entityBalances?['gold_details'] as Map<String, dynamic>?)?.map(
          (key, value) =>
              MapEntry(key, (value is num) ? value.toDouble() : 0.0),
        ) ??
        {};

    List<StatementLine> linesWithBalances = [];
    for (var line in statementLines) {
      runningGold += line.goldDebit - line.goldCredit;
      runningCash += line.cashDebit - line.cashCredit;
      linesWithBalances.add(
        line.copyWith(
          runningGoldBalance: runningGold,
          runningCashBalance: runningCash,
        ),
      );
    }

    return AccountStatement(
      openingBalanceGold:
          json['opening_balance_gold_normalized']?.toDouble() ?? 0.0,
      openingBalanceCash: json['opening_balance_cash']?.toDouble() ?? 0.0,
      closingBalanceGoldNormalized:
          json['closing_balance_gold_normalized']?.toDouble() ?? 0.0,
      closingBalanceCash: json['closing_balance_cash']?.toDouble() ?? 0.0,
      closingBalanceGoldDetails:
          (json['closing_balance_gold_details'] as Map<String, dynamic>?)?.map(
            (key, value) =>
                MapEntry(key, (value is num) ? value.toDouble() : 0.0),
          ) ??
          {},
      entityBalanceGoldNormalized: entityBalances?['gold_normalized'] != null
          ? (entityBalances?['gold_normalized'] as num).toDouble()
          : null,
      entityBalanceCash: entityBalances?['cash'] != null
          ? (entityBalances?['cash'] as num).toDouble()
          : null,
      entityBalanceGoldDetails: entityBalanceGoldDetails,
      mainKarat: json['main_karat'] ?? 21,
      totalDebitGold:
          json['totals']?['gold_debit_normalized']?.toDouble() ?? 0.0,
      totalCreditGold:
          json['totals']?['gold_credit_normalized']?.toDouble() ?? 0.0,
      totalDebitCash: json['totals']?['cash_debit']?.toDouble() ?? 0.0,
      totalCreditCash: json['totals']?['cash_credit']?.toDouble() ?? 0.0,
      lines: linesWithBalances,
    );
  }
}

extension AccountStatementDisplay on AccountStatement {
  double get effectiveClosingGold =>
      entityBalanceGoldNormalized ?? closingBalanceGoldNormalized;

  double get effectiveClosingCash => entityBalanceCash ?? closingBalanceCash;

  Map<String, double> get effectiveClosingGoldDetails =>
      entityBalanceGoldDetails.isNotEmpty
      ? entityBalanceGoldDetails
      : closingBalanceGoldDetails;

  bool get hasEntityBalances =>
      entityBalanceCash != null || entityBalanceGoldNormalized != null;
}

@immutable
class StatementLine {
  final int id;
  final DateTime date;
  final String description;
  final double goldDebit;
  final double goldCredit;
  final double cashDebit;
  final double cashCredit;
  final double? runningGoldBalance;
  final double? runningCashBalance;

  // Optional reference metadata (may be omitted by some endpoints/versions).
  final int? journalEntryId;
  final String? entryNumber;
  final String? referenceType;
  final int? referenceId;
  final String? referenceNumber;

  final double debit18k;
  final double credit18k;
  final double debit21k;
  final double credit21k;
  final double debit22k;
  final double credit22k;
  final double debit24k;
  final double credit24k;

  const StatementLine({
    required this.id,
    required this.date,
    required this.description,
    required this.goldDebit,
    required this.goldCredit,
    required this.cashDebit,
    required this.cashCredit,
    this.runningGoldBalance,
    this.runningCashBalance,
    this.journalEntryId,
    this.entryNumber,
    this.referenceType,
    this.referenceId,
    this.referenceNumber,
    required this.debit18k,
    required this.credit18k,
    required this.debit21k,
    required this.credit21k,
    required this.debit22k,
    required this.credit22k,
    required this.debit24k,
    required this.credit24k,
  });

  // bool get isCredit => goldCredit > 0 || cashCredit > 0;
  // double get goldAmount => isCredit ? goldCredit : goldDebit;
  // double get cashAmount => isCredit ? cashCredit : cashDebit;

  factory StatementLine.fromJson(Map<String, dynamic> json) {
    return StatementLine(
      id: json['id'],
      date: DateTime.parse(json['date']),
      description: json['description'] ?? '',
      journalEntryId: json['journal_entry_id'] as int?,
      entryNumber: json['entry_number']?.toString(),
      referenceType: json['reference_type']?.toString(),
      referenceId: json['reference_id'] is int
          ? (json['reference_id'] as int)
          : int.tryParse(json['reference_id']?.toString() ?? ''),
      referenceNumber: json['reference_number']?.toString(),
      goldDebit: json['gold_debit']?.toDouble() ?? 0.0,
      goldCredit: json['gold_credit']?.toDouble() ?? 0.0,
      cashDebit: json['cash_debit']?.toDouble() ?? 0.0,
      cashCredit: json['cash_credit']?.toDouble() ?? 0.0,
      debit18k: json['debit_18k']?.toDouble() ?? 0.0,
      credit18k: json['credit_18k']?.toDouble() ?? 0.0,
      debit21k: json['debit_21k']?.toDouble() ?? 0.0,
      credit21k: json['credit_21k']?.toDouble() ?? 0.0,
      debit22k: json['debit_22k']?.toDouble() ?? 0.0,
      credit22k: json['credit_22k']?.toDouble() ?? 0.0,
      debit24k: json['debit_24k']?.toDouble() ?? 0.0,
      credit24k: json['credit_24k']?.toDouble() ?? 0.0,
    );
  }

  StatementLine copyWith({
    double? runningGoldBalance,
    double? runningCashBalance,
  }) {
    return StatementLine(
      id: id,
      date: date,
      description: description,
      journalEntryId: journalEntryId,
      entryNumber: entryNumber,
      referenceType: referenceType,
      referenceId: referenceId,
      referenceNumber: referenceNumber,
      goldDebit: goldDebit,
      goldCredit: goldCredit,
      cashDebit: cashDebit,
      cashCredit: cashCredit,
      runningGoldBalance: runningGoldBalance ?? this.runningGoldBalance,
      runningCashBalance: runningCashBalance ?? this.runningCashBalance,
      debit18k: debit18k,
      credit18k: credit18k,
      debit21k: debit21k,
      credit21k: credit21k,
      debit22k: debit22k,
      credit22k: credit22k,
      debit24k: debit24k,
      credit24k: credit24k,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatementLine &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
