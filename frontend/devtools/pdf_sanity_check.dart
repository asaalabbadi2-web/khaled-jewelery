import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart' as pdf;

import 'package:frontend/models/account_statement_model.dart';
import 'package:frontend/pdf/account_statement_pdf_builder.dart';

StatementLine _line({
  required int id,
  required DateTime date,
  required String desc,
  double goldDebit = 0,
  double goldCredit = 0,
  double cashDebit = 0,
  double cashCredit = 0,
}) {
  return StatementLine(
    id: id,
    date: date,
    description: desc,
    journalEntryId: null,
    entryNumber: null,
    referenceType: null,
    referenceId: null,
    referenceNumber: null,
    goldDebit: goldDebit,
    goldCredit: goldCredit,
    cashDebit: cashDebit,
    cashCredit: cashCredit,
    runningGoldBalance: null,
    runningCashBalance: null,
    debit18k: 0,
    credit18k: 0,
    debit21k: 0,
    credit21k: 0,
    debit22k: 0,
    credit22k: 0,
    debit24k: 0,
    credit24k: 0,
  );
}

AccountStatement _mockStatement({
  required List<StatementLine> lines,
  required double openingGold,
  required double openingCash,
  double? goldPricePerGramMainKarat,
  double? valuationTotalValueEstimate,
  int mainKarat = 21,
}) {
  double totalDebitGold = 0;
  double totalCreditGold = 0;
  double totalDebitCash = 0;
  double totalCreditCash = 0;

  double closingGold = openingGold;
  double closingCash = openingCash;

  for (final l in lines) {
    totalDebitGold += l.goldDebit;
    totalCreditGold += l.goldCredit;
    totalDebitCash += l.cashDebit;
    totalCreditCash += l.cashCredit;

    closingGold += l.goldDebit - l.goldCredit;
    closingCash += l.cashDebit - l.cashCredit;
  }

  return AccountStatement(
    openingBalanceGold: openingGold,
    openingBalanceCash: openingCash,
    openingBalanceGoldDetails: const {},
    closingBalanceGoldNormalized: closingGold,
    closingBalanceCash: closingCash,
    closingBalanceGoldDetails: const {},
    mainKarat: mainKarat,
    totalDebitGold: totalDebitGold,
    totalCreditGold: totalCreditGold,
    totalDebitCash: totalDebitCash,
    totalCreditCash: totalCreditCash,
    lines: lines,
    goldPricePerGramMainKarat: goldPricePerGramMainKarat,
    goldPriceSource: goldPricePerGramMainKarat == null ? null : 'mock',
    goldPriceUpdatedAt: goldPricePerGramMainKarat == null ? null : DateTime.now(),
    valuationGoldValueEstimate: null,
    valuationTotalValueEstimate: valuationTotalValueEstimate,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('PDF sanity (A/B/C/D) + valuation banner gating', () async {
    final samplesDir = Directory('devtools/samples');
    if (!samplesDir.existsSync()) {
      samplesDir.createSync(recursive: true);
    }

    const branding = AccountStatementPdfBranding(
      companyName: 'Yasar Gold',
      companyAddress: 'Riyadh',
      companyPhone: '0500000000',
      companyVat: '300000000000003',
      companyCr: '1010101010',
      showCompanyLogo: true,
      companyLogoBase64: '',
    );

    final baseDate = DateTime(2026, 3, 1);
    final movementLines = <StatementLine>[
      _line(
        id: 1,
        date: baseDate,
        desc: 'شراء ذهب',
        goldDebit: 1.200,
      ),
      _line(
        id: 2,
        date: baseDate.add(const Duration(days: 1)),
        desc: 'بيع جزئي + دفعة نقدية',
        goldCredit: 0.300,
        cashDebit: 100.00,
      ),
      _line(
        id: 3,
        date: baseDate.add(const Duration(days: 2)),
        desc: 'سحب نقدي',
        cashCredit: 50.00,
      ),
    ];

    final statementWithValuation = _mockStatement(
      lines: movementLines,
      openingGold: 5.000,
      openingCash: 1000.00,
      goldPricePerGramMainKarat: 250.00,
      valuationTotalValueEstimate: 12345.67,
    );

    final statementNoMovements = _mockStatement(
      lines: const [],
      openingGold: 5.000,
      openingCash: 1000.00,
      goldPricePerGramMainKarat: null,
      valuationTotalValueEstimate: null,
    );

    Future<({
      List<int> bytes,
      bool valuationBannerRendered,
    })> buildAndSave({
      required String filename,
      required AccountStatement statement,
      required List<StatementLine> tableLines,
      required int viewMode,
      required bool includeValuation,
    }) async {
      bool rendered = false;
      final bytes = await AccountStatementPdfBuilder.build(
        pdf.PdfPageFormat.a4,
        statement: statement,
        tableLines: tableLines,
        accountName: 'حساب تجريبي',
        accountId: 999,
        viewMode: viewMode,
        includeValuation: includeValuation,
        dateRange: null,
        filterType: 'all',
        showOnlyMovement: false,
        branding: branding,
        debugProbe: ({required valuationBannerRendered, required goldPriceChipRendered}) {
          rendered = valuationBannerRendered;
        },
      );

      final outPath = samplesDir.uri.resolve(filename).toFilePath();
      await File(outPath).writeAsBytes(bytes, flush: true);

      return (bytes: bytes, valuationBannerRendered: rendered);
    }

    // A) Full (dual) + valuation ON
    final a = await buildAndSave(
      filename: 'statement_full_valuation.pdf',
      statement: statementWithValuation,
      tableLines: movementLines,
      viewMode: 0,
      includeValuation: true,
    );

    // B) Gold only (valuation ON but must be hidden)
    final b = await buildAndSave(
      filename: 'statement_gold_only.pdf',
      statement: statementWithValuation,
      tableLines: movementLines,
      viewMode: 1,
      includeValuation: true,
    );

    // C) Cash only (valuation ON but must be hidden)
    final c = await buildAndSave(
      filename: 'statement_cash_only.pdf',
      statement: statementWithValuation,
      tableLines: movementLines,
      viewMode: 2,
      includeValuation: true,
    );

    // D) No movements (no valuation data; banner must be hidden)
    final d = await buildAndSave(
      filename: 'statement_no_movements.pdf',
      statement: statementNoMovements,
      tableLines: const [],
      viewMode: 0,
      includeValuation: true,
    );

    expect(a.bytes, isNotEmpty);
    expect(b.bytes, isNotEmpty);
    expect(c.bytes, isNotEmpty);
    expect(d.bytes, isNotEmpty);

    expect(a.valuationBannerRendered, isTrue);
    expect(b.valuationBannerRendered, isFalse);
    expect(c.valuationBannerRendered, isFalse);
    expect(d.valuationBannerRendered, isFalse);
  });
}
