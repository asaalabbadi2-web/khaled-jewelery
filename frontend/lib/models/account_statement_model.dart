import 'package:flutter/foundation.dart';

class AccountStatement {
  final double openingBalanceGold;
  final double openingBalanceCash;
  final Map<String, double> openingBalanceGoldDetails;
  final double closingBalanceGoldNormalized;
  final double closingBalanceCash;
  final Map<String, double> closingBalanceGoldDetails;
  final int mainKarat;
  final double totalDebitGold;
  final double totalCreditGold;
  final double totalDebitCash;
  final double totalCreditCash;
  final List<StatementLine> lines;

  // When true, the backend combined a financial account with its linked memo
  // account (cash/value from the financial side + weight from the memo side).
  final bool isMerged;
  final String? memoAccountName;

  // Optional signed QR fields (server-side HMAC seal).
  // When present, these allow embedding a tamper-evident payload in the PDF QR.
  final DateTime? qrIssuedAt;
  final Map<String, dynamic>? qrSignedPayload;
  final String? qrSignature;
  final String? qrVerifyToken;
  final String? qrVerifyUrl;

  // Optional live price + valuation (may be omitted by some endpoints/versions).
  final double? goldPricePerGramMainKarat;
  final String? goldPriceSource;
  final DateTime? goldPriceUpdatedAt;
  final double? valuationGoldValueEstimate;
  final double? valuationTotalValueEstimate;

  /// Cancelled vouchers and their reversals the server left out of [lines]
  /// (hidden by default; the owner, 9 Oct 2026). Their count is given either
  /// way, so the screen can offer to show them.
  final int cancelledCount;
  final List<String> cancelledVoucherNumbers;
  final bool cancelledHidden;

  /// Payment-method corrections hidden with the payment they moved, in the
  /// wrong method's statement (the owner, 9 Oct 2026).
  final int correctionCount;

  AccountStatement({
    required this.openingBalanceGold,
    required this.openingBalanceCash,
    required this.openingBalanceGoldDetails,
    required this.closingBalanceGoldNormalized,
    required this.closingBalanceCash,
    required this.closingBalanceGoldDetails,
    required this.mainKarat,
    required this.totalDebitGold,
    required this.totalCreditGold,
    required this.totalDebitCash,
    required this.totalCreditCash,
    required this.lines,
    this.isMerged = false,
    this.memoAccountName,
    this.qrIssuedAt,
    this.qrSignedPayload,
    this.qrSignature,
    this.qrVerifyToken,
    this.qrVerifyUrl,
    this.goldPricePerGramMainKarat,
    this.goldPriceSource,
    this.goldPriceUpdatedAt,
    this.valuationGoldValueEstimate,
    this.valuationTotalValueEstimate,
    this.cancelledCount = 0,
    this.cancelledVoucherNumbers = const [],
    this.cancelledHidden = false,
    this.correctionCount = 0,
  });

  factory AccountStatement.fromJson(Map<String, dynamic> json) {
    var linesFromJson = json['lines'] as List? ?? [];
    List<StatementLine> statementLines = linesFromJson
        .map((i) => StatementLine.fromJson(i))
        .toList();


    final priceSnapshot = json['gold_price_snapshot'] as Map<String, dynamic>?;
    final valuation = json['valuation'] as Map<String, dynamic>?;
    final rawUpdatedAt = priceSnapshot?['updated_at']?.toString();
    DateTime? parsedUpdatedAt;
    if (rawUpdatedAt != null && rawUpdatedAt.isNotEmpty) {
      try {
        parsedUpdatedAt = DateTime.parse(rawUpdatedAt);
      } catch (_) {
        parsedUpdatedAt = null;
      }
    }

    double? asDouble(dynamic value) {
      if (value == null) return null;
      if (value is num) return value.toDouble();
      return double.tryParse(value.toString());
    }

    final rawQrIssuedAt = json['qr_issued_at']?.toString();
    DateTime? parsedQrIssuedAt;
    if (rawQrIssuedAt != null && rawQrIssuedAt.trim().isNotEmpty) {
      try {
        parsedQrIssuedAt = DateTime.parse(rawQrIssuedAt.trim());
      } catch (_) {
        parsedQrIssuedAt = null;
      }
    }

    Map<String, dynamic>? qrSignedPayload;
    final rawSigned = json['qr_signed_payload'];
    if (rawSigned is Map) {
      qrSignedPayload = rawSigned.map(
        (key, value) => MapEntry(key.toString(), value),
      );
    }

    final rawSig = (json['qr_signature'] ?? '').toString().trim();
    final qrSignature = rawSig.isEmpty ? null : rawSig;

    final rawVerifyToken = (json['qr_verify_token'] ?? '').toString().trim();
    final qrVerifyToken = rawVerifyToken.isEmpty ? null : rawVerifyToken;

    final rawVerifyUrl = (json['qr_verify_url'] ?? '').toString().trim();
    final qrVerifyUrl = rawVerifyUrl.isEmpty ? null : rawVerifyUrl;

    final cancelled = json['cancelled_hidden'] as Map<String, dynamic>?;

    return AccountStatement(
      cancelledCount: (cancelled?['count'] as num?)?.toInt() ?? 0,
      cancelledVoucherNumbers: ((cancelled?['vouchers'] as List?) ?? const [])
          .map((v) => v.toString())
          .toList(),
      cancelledHidden: cancelled?['hidden'] == true,
      correctionCount: (cancelled?['corrections'] as num?)?.toInt() ?? 0,
      openingBalanceGold:
          json['opening_balance_gold_normalized']?.toDouble() ?? 0.0,
      openingBalanceCash: json['opening_balance_cash']?.toDouble() ?? 0.0,
      openingBalanceGoldDetails:
          (json['opening_balance_gold_details'] as Map<String, dynamic>?)?.map(
            (key, value) =>
                MapEntry(key, (value is num) ? value.toDouble() : 0.0),
          ) ??
          {},
      closingBalanceGoldNormalized:
          json['closing_balance_gold_normalized']?.toDouble() ?? 0.0,
      closingBalanceCash: json['closing_balance_cash']?.toDouble() ?? 0.0,
      closingBalanceGoldDetails:
          (json['closing_balance_gold_details'] as Map<String, dynamic>?)?.map(
            (key, value) =>
                MapEntry(key, (value is num) ? value.toDouble() : 0.0),
          ) ??
          {},
      mainKarat: json['main_karat'] ?? 21,
      totalDebitGold:
          json['totals']?['gold_debit_normalized']?.toDouble() ?? 0.0,
      totalCreditGold:
          json['totals']?['gold_credit_normalized']?.toDouble() ?? 0.0,
      totalDebitCash: json['totals']?['cash_debit']?.toDouble() ?? 0.0,
      totalCreditCash: json['totals']?['cash_credit']?.toDouble() ?? 0.0,
      lines: statementLines,

      isMerged: (json['is_merged'] == true) || (json['is_merged'] == 1),
      memoAccountName: (json['memo_account_name'] ?? '').toString().trim().isEmpty
          ? null
          : (json['memo_account_name'] ?? '').toString().trim(),

      qrIssuedAt: parsedQrIssuedAt,
      qrSignedPayload: qrSignedPayload,
      qrSignature: qrSignature,
      qrVerifyToken: qrVerifyToken,
      qrVerifyUrl: qrVerifyUrl,

      goldPricePerGramMainKarat:
          asDouble(priceSnapshot?['price_per_gram_main_karat']) ??
          asDouble(valuation?['price_per_gram_main_karat']),
      goldPriceSource: priceSnapshot?['source']?.toString(),
      goldPriceUpdatedAt: parsedUpdatedAt,
      valuationGoldValueEstimate: asDouble(valuation?['gold_value_estimate']),
      valuationTotalValueEstimate: asDouble(valuation?['total_value_estimate']),
    );
  }
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
  /// The balance after this line, as the server computes the closing: the
  /// screen shows it, and a filter hides lines without ever recomputing it
  /// (10 Oct 2026 -- it used to restart from the filtered lines).
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
      runningGoldBalance: (json['running_gold_balance'] as num?)?.toDouble(),
      runningCashBalance: (json['running_cash_balance'] as num?)?.toDouble(),
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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StatementLine &&
          runtimeType == other.runtimeType &&
          id == other.id;

  @override
  int get hashCode => id.hashCode;
}
