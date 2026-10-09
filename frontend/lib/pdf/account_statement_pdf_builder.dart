import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart' as pdf;
import 'package:pdf/widgets.dart' as pw;

import '../models/account_statement_model.dart';
import 'pdf_text_utils.dart';

// ═══════════════════════════════════════════════════════════════════
//  DESIGN TOKENS  — single source of truth for the PDF theme
// ═══════════════════════════════════════════════════════════════════
class _PdfColors {
  static final gold       = pdf.PdfColor.fromHex('#8B6914');
  static final goldMid    = pdf.PdfColor.fromHex('#A07820');
  static final goldLight  = pdf.PdfColor.fromHex('#C9A84C');
  static final goldBg     = pdf.PdfColor.fromHex('#FBF7EE');
  static final borderLight= pdf.PdfColor.fromHex('#E8D899');

  static final black  = pdf.PdfColor.fromHex('#111111');
  static final dark   = pdf.PdfColor.fromHex('#222222');
  static final body   = pdf.PdfColor.fromHex('#333333');
  static final muted  = pdf.PdfColor.fromHex('#444444');
  static final white  = pdf.PdfColors.white;

  static final negative = pdf.PdfColor.fromHex('#7B2537');   // dark burgundy
  static final positive = pdf.PdfColor.fromHex('#2A5E42');   // muted forest green

  // Row banding colors (match the reference screenshot tone)
  static final rowAlt  = pdf.PdfColor.fromHex('#F5EFE0');
  static final rowOpen = pdf.PdfColor.fromHex('#EDE3C0');
}

class AccountStatementPdfBranding {
  final String companyName;
  final String companyAddress;
  final String companyPhone;
  final String companyVat;
  final String companyCr;
  final bool showCompanyLogo;
  final String companyLogoBase64;
  final String currencySymbol;
  final bool isNewSar;

  final bool blackAndWhite;

  const AccountStatementPdfBranding({
    required this.companyName,
    required this.companyAddress,
    required this.companyPhone,
    required this.companyVat,
    required this.companyCr,
    required this.showCompanyLogo,
    required this.companyLogoBase64,
    this.currencySymbol = 'ر.س',
    this.isNewSar = false,
    this.blackAndWhite = false,
  });
}

class AccountStatementPdfBuilder {
  static const String defaultLegalFooterText =
      'يعتبر هذا الكشف مصدقاً وصحيحاً ما لم يرد اعتراض خطي خلال 7 أيام من تاريخه. تطبق الشروط والأحكام.';
  static const String digitalDocumentFooterText =
      'هذا المستند تم إنشاؤه آلياً وموثق رقمياً، ولا يحتاج إلى ختم يدوى   .';

  static ({DateTime startInclusive, DateTime endExclusive}) _rangeBounds(
    DateTimeRange range,
  ) {
    final start = DateTime(range.start.year, range.start.month, range.start.day);
    final endExclusive = DateTime(
      range.end.year,
      range.end.month,
      range.end.day,
    ).add(const Duration(days: 1));
    return (startInclusive: start, endExclusive: endExclusive);
  }

  static ({double gold, double cash}) _openingBalanceAt(
    AccountStatement statement,
    DateTime? start,
  ) {
    if (start == null) {
      return (gold: statement.openingBalanceGold, cash: statement.openingBalanceCash);
    }

    double gold = statement.openingBalanceGold;
    double cash = statement.openingBalanceCash;

    for (final line in statement.lines) {
      if (line.date.isBefore(start)) {
        gold += line.goldDebit - line.goldCredit;
        cash += line.cashDebit - line.cashCredit;
      }
    }

    return (gold: gold, cash: cash);
  }

  static ({
    double openingGold,
    double openingCash,
    double movementGold,
    double movementCash,
    double closingGold,
    double closingCash,
  }) _periodSummary(AccountStatement statement, DateTimeRange? dateRange) {
    if (dateRange == null) {
      final movementGold = statement.totalDebitGold - statement.totalCreditGold;
      final movementCash = statement.totalDebitCash - statement.totalCreditCash;
      return (
        openingGold: statement.openingBalanceGold,
        openingCash: statement.openingBalanceCash,
        movementGold: movementGold,
        movementCash: movementCash,
        closingGold: statement.effectiveClosingGold,
        closingCash: statement.effectiveClosingCash,
      );
    }

    final bounds = _rangeBounds(dateRange);
    final opening = _openingBalanceAt(statement, bounds.startInclusive);

    double movementGold = 0.0;
    double movementCash = 0.0;

    for (final line in statement.lines) {
      final dt = line.date;
      final inRange =
          !dt.isBefore(bounds.startInclusive) && dt.isBefore(bounds.endExclusive);
      if (!inRange) continue;
      movementGold += line.goldDebit - line.goldCredit;
      movementCash += line.cashDebit - line.cashCredit;
    }

    return (
      openingGold: opening.gold,
      openingCash: opening.cash,
      movementGold: movementGold,
      movementCash: movementCash,
      closingGold: opening.gold + movementGold,
      closingCash: opening.cash + movementCash,
    );
  }

  static ({double goldDebit, double goldCredit, double cashDebit, double cashCredit})
      _periodDebitCreditTotals(AccountStatement statement, DateTimeRange? dateRange) {
    if (dateRange == null) {
      return (
        goldDebit: statement.totalDebitGold,
        goldCredit: statement.totalCreditGold,
        cashDebit: statement.totalDebitCash,
        cashCredit: statement.totalCreditCash,
      );
    }

    final bounds = _rangeBounds(dateRange);
    double goldDebit = 0.0;
    double goldCredit = 0.0;
    double cashDebit = 0.0;
    double cashCredit = 0.0;

    for (final line in statement.lines) {
      final dt = line.date;
      final inRange =
          !dt.isBefore(bounds.startInclusive) && dt.isBefore(bounds.endExclusive);
      if (!inRange) continue;
      goldDebit += line.goldDebit;
      goldCredit += line.goldCredit;
      cashDebit += line.cashDebit;
      cashCredit += line.cashCredit;
    }

    return (
      goldDebit: goldDebit,
      goldCredit: goldCredit,
      cashDebit: cashDebit,
      cashCredit: cashCredit,
    );
  }

  static List<StatementLine> _ensureRunningBalances(AccountStatement statement) {
    final anyMissing = statement.lines.any(
      (l) => l.runningGoldBalance == null || l.runningCashBalance == null,
    );
    if (!anyMissing) return statement.lines;

    final sorted = [...statement.lines]
      ..sort((a, b) {
        final byDate = a.date.compareTo(b.date);
        if (byDate != 0) return byDate;
        return a.id.compareTo(b.id);
      });

    double runningGold = statement.openingBalanceGold;
    double runningCash = statement.openingBalanceCash;

    final withBalances = <StatementLine>[];
    for (final line in sorted) {
      runningGold += line.goldDebit - line.goldCredit;
      runningCash += line.cashDebit - line.cashCredit;
      withBalances.add(
        line.copyWith(runningGoldBalance: runningGold, runningCashBalance: runningCash),
      );
    }

    final byId = {for (final l in withBalances) l.id: l};
    return statement.lines.map((l) => byId[l.id] ?? l).toList();
  }

  static pw.MemoryImage? _decodeBase64Image(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;

    var payload = s;
    final commaIndex = payload.indexOf(',');
    if (payload.startsWith('data:') && commaIndex >= 0) {
      payload = payload.substring(commaIndex + 1);
    }

    try {
      final bytes = base64Decode(payload);
      if (bytes.isEmpty) return null;
      return pw.MemoryImage(bytes);
    } catch (_) {
      return null;
    }
  }

  static Future<pw.MemoryImage?> _tryLoadImage(String assetPath) async {
    try {
      final bytes = (await rootBundle.load(assetPath)).buffer.asUint8List();
      return pw.MemoryImage(bytes);
    } catch (_) {
      return null;
    }
  }

  static Future<Uint8List> build(
    pdf.PdfPageFormat pageFormat, {
    required AccountStatement statement,
    required List<StatementLine> tableLines,
    required String accountName,
    required int accountId,
    required int viewMode,
    required bool includeValuation,
    required DateTimeRange? dateRange,
    required String filterType,
    required bool showOnlyMovement,
    required AccountStatementPdfBranding branding,
    String legalFooterText = defaultLegalFooterText,
    // Optional pre-loaded assets — pass these when calling from a background
    // isolate so that rootBundle (unavailable there) is never accessed inside.
    Uint8List? preloadedRegularFont,
    Uint8List? preloadedBoldFont,
    Uint8List? preloadedFallbackLogo,
    // Pre-resized logo bytes (resized on the main isolate before spawning).
    Uint8List? preloadedLogo,
    // Pre-tinted SAR symbol bytes (gold tone for amounts, dark for body text).
    Uint8List? sarGoldBytes,
    Uint8List? sarDarkBytes,
    void Function({
      required bool valuationBannerRendered,
      required bool goldPriceChipRendered,
    })?
    debugProbe,
  }) async {
    // ── fonts ──────────────────────────────────────────────────────
    final fontData = preloadedRegularFont != null
        ? ByteData.view(preloadedRegularFont.buffer)
        : await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    final boldFontData = preloadedBoldFont != null
        ? ByteData.view(preloadedBoldFont.buffer)
        : await rootBundle.load('assets/fonts/Cairo-Bold.ttf');
    final baseFont = pw.Font.ttf(fontData);
    final boldFont = pw.Font.ttf(boldFontData);
    final theme = pw.ThemeData.withFont(base: baseFont, bold: boldFont);

    // ── data prep ─────────────────────────────────────────────────
    final mainKarat = statement.mainKarat;
    final isMerged = statement.isMerged;
    final cashLabel = isMerged ? 'قيمة' : 'نقد';
    final currencySymbol = branding.currencySymbol;
    final isNewSar = branding.isNewSar;

    // SAR image providers (null when not using new symbol).
    final sarGoldImg = sarGoldBytes != null ? pw.MemoryImage(sarGoldBytes) : null;
    final sarDarkImg = sarDarkBytes != null ? pw.MemoryImage(sarDarkBytes) : null;

    // Inline cash amount widget — shows SAR image when isNewSar is true.
    pw.Widget buildCashAmt(
      String numStr, {
      required pw.Font font,
      required double fontSize,
      required pdf.PdfColor color,
      bool useDark = false,
    }) {
      final sarImg = useDark ? sarDarkImg : sarGoldImg;
      if (isNewSar && sarImg != null) {
        // Page is RTL so pw.Row reverses child order automatically.
        // [num, spacer, img] → RTL flip → num RIGHT, img LEFT → number first (correct).
        return pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text(numStr,
                textDirection: pw.TextDirection.ltr,
                style: pw.TextStyle(font: font, fontSize: fontSize, color: color)),
            pw.SizedBox(width: 2),
            pw.Image(sarImg, width: fontSize * 0.72, height: fontSize),
          ],
        );
      }
      return pw.Text(
        '$numStr $currencySymbol',
        textDirection: pw.TextDirection.ltr,
        style: pw.TextStyle(font: font, fontSize: fontSize, color: color),
      );
    }

    final statementLinesWithBalances = _ensureRunningBalances(statement);
    final statementLineById = {
      for (final l in statementLinesWithBalances) l.id: l,
    };
    final resolvedTableLines = tableLines
        .map((l) => statementLineById[l.id] ?? l)
        .toList(growable: false);

    // ── period computations ───────────────────────────────────────
    final period = _periodSummary(statement, dateRange);
    final totals = _periodDebitCreditTotals(statement, dateRange);
    final commaFmt = NumberFormat('#,##0.00', 'en_US');

    final periodClosingGold =
        dateRange == null ? statement.effectiveClosingGold : period.closingGold;
    final periodClosingCash =
        dateRange == null ? statement.effectiveClosingCash : period.closingCash;

    final pricePerGram = statement.goldPricePerGramMainKarat;
    final valuationGoldValue = statement.valuationGoldValueEstimate ??
        ((pricePerGram == null) ? null : (periodClosingGold * pricePerGram));
    final valuationCashBalance = periodClosingCash;
    final valuationNet = statement.valuationTotalValueEstimate ??
        ((valuationGoldValue ?? 0.0) + valuationCashBalance);

    final showGoldPriceChip = includeValuation && viewMode != 2;
    final showValuationBanner = includeValuation && viewMode == 0;
    final hasValuationData =
        (valuationGoldValue != null) || (statement.valuationTotalValueEstimate != null);
    final valuationBannerRendered = showValuationBanner &&
        hasValuationData &&
        (valuationNet != 0 || valuationCashBalance != 0 || periodClosingGold != 0);
    final goldPriceChipRendered =
        showGoldPriceChip && (pricePerGram ?? 0) > 0;

    debugProbe?.call(
      valuationBannerRendered: valuationBannerRendered,
      goldPriceChipRendered: goldPriceChipRendered,
    );

    // ── document meta ─────────────────────────────────────────────
    final now = DateTime.now();
    final issuedAtText = DateFormat('yyyy-MM-dd').format(now);
    final statementId =
        'ST-${DateFormat('yyyyMMdd-HHmmss').format(now)}-$accountId';
    final dateRangeText = dateRange == null
        ? '—'
        : '${DateFormat('yyyy-MM-dd').format(dateRange.start)} – ${DateFormat('yyyy-MM-dd').format(dateRange.end)}';

    final viewModeLabel = switch (viewMode) {
      1 => 'ذهب فقط',
      2 => isMerged ? 'قيمة فقط' : 'نقد فقط',
      _ => isMerged ? 'ذهب + قيمة' : 'ذهب + نقد',
    };
    // filterLabel reserved for future use
    // ignore: unused_local_variable
    final filterLabel = switch (filterType) {
      'credit' => 'دائن',
      'debit' => 'مدين',
      _ => 'الكل',
    };

    // ── QR payload ────────────────────────────────────────────────
    // NOTE: QR encoding can throw (e.g., oversized payload). We generate
    // fallbacks and pick the first one that encodes successfully.
    final canEmbedSignature =
      dateRange == null && statement.qrSignedPayload != null;

    final fullQrPayload = jsonEncode(canEmbedSignature
      ? <String, dynamic>{
        'statement_id': statementId,
        'algo': 'HS256',
        'signed': statement.qrSignedPayload,
        if ((statement.qrSignature ?? '').trim().isNotEmpty)
          'sig': statement.qrSignature,
        }
      : <String, dynamic>{
        'org': branding.companyName,
        'statement_id': statementId,
        'account': accountName,
        'issued_at': issuedAtText,
        'main_karat': mainKarat,
        'closing_gold_g':
          double.parse(periodClosingGold.toStringAsFixed(3)),
        'closing_cash':
          double.parse(periodClosingCash.toStringAsFixed(2)),
        'is_merged': isMerged,
        });

    final shortQrPayload = jsonEncode(<String, dynamic>{
      'org': branding.companyName,
      'statement_id': statementId,
      'issued_at': issuedAtText,
    });

    final verifyUrl = (dateRange == null)
        ? (statement.qrVerifyUrl ?? '').trim()
        : '';

    final qrCandidates = <String>[
      if (verifyUrl.isNotEmpty) verifyUrl,
      fullQrPayload,
      shortQrPayload,
      // Last resort: plain identifier.
      'statement_id=$statementId',
    ];

    // Pick the first QR payload that actually encodes successfully.
    // Some failures (like oversized payloads) can throw during rendering.
    final qrBarcode = pw.Barcode.qrCode();
    String? qrData;
    for (final candidate in qrCandidates) {
      try {
        // Force-encode once to validate. If this succeeds, BarcodeWidget should
        // also succeed with the same dimensions.
        qrBarcode.make(candidate, width: 32, height: 32);
        qrData = candidate;
        break;
      } catch (_) {
        // Try next candidate.
      }
    }

    // ── logo ──────────────────────────────────────────────────────
    // preloadedLogo takes priority — it is pre-decoded and resized on the
    // main isolate before being handed off to a background isolate.
    final logoImage = preloadedLogo != null
        ? pw.MemoryImage(preloadedLogo)
        : (_decodeBase64Image(branding.companyLogoBase64) ??
            (preloadedFallbackLogo != null
                ? pw.MemoryImage(preloadedFallbackLogo)
                : await _tryLoadImage('assets/KHGL.png')));

    // ── column definitions ────────────────────────────────────────
    const dateKey = 'date';
    const refKey = 'reference';
    const descKey = 'desc';
    const goldDebitKey = 'gold_debit';
    const goldCreditKey = 'gold_credit';
    const goldBalKey = 'gold_balance';
    const cashDebitKey = 'cash_debit';
    const cashCreditKey = 'cash_credit';
    const cashBalKey = 'cash_balance';

    final valueColumns = <({String key, String header})>[];
    if (viewMode != 2) {
      valueColumns.addAll([
        (key: goldDebitKey, header: 'ذهب مدين\n(${mainKarat}k)'),
        (key: goldCreditKey, header: 'ذهب دائن\n(${mainKarat}k)'),
        (key: goldBalKey, header: 'رصيد الذهب\n(${mainKarat}k)'),
      ]);
    }
    if (viewMode != 1) {
      valueColumns.addAll([
        (key: cashDebitKey, header: '$cashLabel مدين'),
        (key: cashCreditKey, header: '$cashLabel دائن'),
        (key: cashBalKey, header: 'رصيد $cashLabel'),
      ]);
    }

    // NOTE: pdf/widgets Table does not mirror column order under RTL the same
    // way Flutter does. We therefore order columns in the exact visual order
    // (left → right) to achieve the RTL look (date at far right).
    final columns = <({String key, String header})>[
      ...valueColumns.reversed,
      (key: refKey, header: 'رقم القيد'),
      (key: descKey, header: 'البيان'),
      (key: dateKey, header: 'التاريخ'),
    ];

    final cashCols = {cashDebitKey, cashCreditKey, cashBalKey};
    final colWidths = <int, pw.TableColumnWidth>{
      for (var i = 0; i < columns.length; i++)
        i: columns[i].key == descKey
            ? const pw.FlexColumnWidth(1)
            : columns[i].key == refKey
                ? const pw.FixedColumnWidth(78)
                : columns[i].key == dateKey
                    ? const pw.FixedColumnWidth(56)
                    : cashCols.contains(columns[i].key)
                        ? const pw.FixedColumnWidth(60)
                        : const pw.FixedColumnWidth(48),
    };

    // ─────────────────────────────────────────────────────────────
    //  WIDGET FACTORIES
    // ─────────────────────────────────────────────────────────────

    // Gold gradient rule (top + bottom decorative stripe)
    pw.Widget goldRule({double height = 4}) => pw.Container(
          height: height,
          decoration: const pw.BoxDecoration(
            gradient: pw.LinearGradient(
              colors: [
                pdf.PdfColor.fromInt(0xFF8B6914),
                pdf.PdfColor.fromInt(0xFFC9A84C),
                pdf.PdfColor.fromInt(0xFFE8C97A),
                pdf.PdfColor.fromInt(0xFFC9A84C),
                pdf.PdfColor.fromInt(0xFF8B6914),
              ],
            ),
          ),
        );

    // Thin separator line
    pw.Widget thinRule() => pw.Container(
          height: 0.8,
          color: _PdfColors.borderLight,
        );

    // Section heading (label + trailing rule)
    pw.Widget sectionHeading(String title) => pw.Row(
          children: [
            pw.Text(
              pdfVisualArabic(title),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                font: boldFont,
                fontSize: 9,
                color: _PdfColors.goldMid,
              ),
            ),
            pw.SizedBox(width: 8),
            pw.Expanded(
              child: pw.Container(height: 0.8, color: _PdfColors.borderLight),
            ),
          ],
        );

    // Filter strip chip — no border box, just label + value separated by bullet
    pw.Widget filterChip({required String label, required String value}) =>
        pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Text(
              pdfVisualArabic('$label: '),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                  font: baseFont, fontSize: 7.5, color: _PdfColors.muted),
            ),
            pw.Text(
              pdfVisualArabic(value),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                  font: boldFont, fontSize: 7.5, color: _PdfColors.dark),
            ),
          ],
        );

    // ── Balance summary: borderless luxury card ──
    pw.Widget balCell(String label, String value, pdf.PdfColor valueColor,
        {bool highlighted = false}) =>
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 9),
          decoration: pw.BoxDecoration(
            color: highlighted
                ? _PdfColors.goldBg
                : pdf.PdfColor.fromHex('#FAFAF8'),
            borderRadius: const pw.BorderRadius.all(pw.Radius.circular(3)),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.center,
            children: [
              pw.Text(
                pdfVisualArabic(label),
                textDirection: pw.TextDirection.ltr,
                style: pw.TextStyle(
                    font: boldFont, fontSize: 7.5, color: _PdfColors.goldMid),
              ),
              pw.SizedBox(height: 5),
              pw.Text(
                value,
                textDirection: pw.TextDirection.ltr,
                style:
                    pw.TextStyle(font: boldFont, fontSize: 14, color: valueColor),
              ),
            ],
          ),
        );

    // Table header cell (two-line: title + unit)
    pw.Widget headerCell(String text, {bool isDesc = false}) {
      final parts = text.split('\n');
      final title = parts.isEmpty ? text : parts.first;
      final unit = parts.length > 1 ? parts.sublist(1).join('\n') : null;

      final isValueCol = !isDesc && unit != null;
      final align = isDesc
          ? pw.Alignment.centerRight
          : isValueCol
              ? pw.Alignment.center
              : pw.Alignment.center;

      return pw.Container(
        alignment: align,
        padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: pw.Column(
          mainAxisSize: pw.MainAxisSize.min,
          crossAxisAlignment:
              isDesc ? pw.CrossAxisAlignment.end : pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              pdfVisualArabic(title),
              textDirection: pw.TextDirection.ltr,
              textAlign: isDesc ? pw.TextAlign.right : pw.TextAlign.center,
              style: pw.TextStyle(
                font: boldFont,
                fontSize: isDesc ? 8 : 7.5,
                color: _PdfColors.dark,
              ),
            ),
            if (unit != null) ...[
              pw.SizedBox(height: 2),
              pw.Text(
                unit,
                textDirection: pw.TextDirection.rtl,
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  font: baseFont,
                  fontSize: 6.2,
                  color: _PdfColors.muted,
                ),
              ),
            ],
          ],
        ),
      );
    }

    // Table data cell
    pw.Widget dataCell(
      String key,
      String text, {
      pdf.PdfColor? color,
      bool bold = false,
      double fontSize = 8,
    }) =>
        pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          alignment: key == descKey
              ? pw.Alignment.centerRight
              : (key == dateKey || key == refKey)
                  ? pw.Alignment.center
                  : pw.Alignment.center,
          child: pw.Text(
            pdfVisualArabic(pdfSanitize(text)),
            // Only description should wrap; keep numbers/refs stable.
            softWrap: key == descKey,
            overflow: key == descKey ? pw.TextOverflow.visible : pw.TextOverflow.clip,
            textAlign: key == descKey
                ? pw.TextAlign.right
                : (key == dateKey || key == refKey)
                    ? pw.TextAlign.center
                    : pw.TextAlign.center,
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
              font: bold ? boldFont : baseFont,
              fontSize: fontSize,
              color: color ?? _PdfColors.body,
            ),
          ),
        );

    // Build one data row's widget list (with color-coded debit/credit)
    List<pw.Widget> buildRowCells(
      Map<String, String> values, {
      bool isOpening = false,
      bool isAlt = false,
    }) {
      final bg = isOpening
          ? _PdfColors.rowOpen
          : isAlt
              ? _PdfColors.rowAlt
              : _PdfColors.white;

      return columns.map((c) {
        final raw = values[c.key] ?? '';

        final isCashCol = c.key == cashDebitKey ||
            c.key == cashCreditKey ||
            c.key == cashBalKey;
        pdf.PdfColor? txtColor;
        bool bold = isOpening;
        double fs = c.key == refKey
            ? 7.0
            : isCashCol
                ? 7.5
                : 8;
        if (c.key == descKey) fs = 7.5;
        if (c.key == refKey) fs = 6.8;

        // Strip commas so double.tryParse works on comma-formatted cash values
        final numRaw = raw.replaceAll(',', '');
        if (!isOpening) {
          if (c.key == goldDebitKey || c.key == cashDebitKey) {
            final v = double.tryParse(numRaw) ?? 0;
            if (v > 0) {
              txtColor = _PdfColors.positive; // مدين → أخضر
              bold = true;
            }
          }
          if (c.key == goldCreditKey || c.key == cashCreditKey) {
            final v = double.tryParse(numRaw) ?? 0;
            if (v > 0) {
              txtColor = _PdfColors.negative; // دائن → أحمر
              bold = true;
            }
          }
          if (c.key == goldBalKey) {
            final v = double.tryParse(numRaw) ?? 0;
            txtColor = v < 0 ? _PdfColors.negative : _PdfColors.positive;
            bold = true;
          }
          if (c.key == cashBalKey) {
            final v = double.tryParse(numRaw) ?? 0;
            txtColor = v < 0 ? _PdfColors.negative : _PdfColors.positive;
            bold = true;
          }
        }

        final cell =
            dataCell(c.key, raw, color: txtColor, bold: bold, fontSize: fs);

        // Match reference: row banding only (no special column tinting).
        return pw.Container(color: bg, child: cell);
      }).toList();
    }

    // ── opening row + data rows ───────────────────────────────────
    final openingValues = <String, String>{
      dateKey: dateRange == null
          ? '—'
          : DateFormat('yyyy-MM-dd').format(dateRange.start),
      refKey: '—',
      descKey: 'رصيد افتتاحي',
      goldDebitKey: '0.000',
      goldCreditKey: '0.000',
      goldBalKey: period.openingGold.toStringAsFixed(3),
      cashDebitKey: '0.00',
      cashCreditKey: '0.00',
      cashBalKey: commaFmt.format(period.openingCash),
    };

    final allRows = <List<pw.Widget>>[
      buildRowCells(openingValues, isOpening: true),
      ...resolvedTableLines.asMap().entries.map((e) {
        final idx = e.key;
        final line = e.value;
        final refParts = <String?>[
          line.referenceNumber,
          line.entryNumber,
          if (line.journalEntryId != null) 'JE-${line.journalEntryId}',
        ]
            .whereType<String>()
            .map((v) => v.trim())
            .where((v) => v.isNotEmpty)
            .toList(growable: false);

        final seen = <String>{};
        final orderedUnique = <String>[];
        for (final p in refParts) {
          if (seen.add(p)) orderedUnique.add(p);
        }

        final ref = orderedUnique.join('\n');

        return buildRowCells(
          {
            dateKey: DateFormat('yyyy-MM-dd').format(line.date),
            refKey: ref.isEmpty ? '—' : ref,
            descKey: line.description,
            goldDebitKey: line.goldDebit.toStringAsFixed(3),
            goldCreditKey: line.goldCredit.toStringAsFixed(3),
            goldBalKey:
                (line.runningGoldBalance ?? 0).toStringAsFixed(3),
            cashDebitKey: commaFmt.format(line.cashDebit),
            cashCreditKey: commaFmt.format(line.cashCredit),
            cashBalKey:
                commaFmt.format(line.runningCashBalance ?? 0),
          },
          isAlt: idx.isOdd,
        );
      }),
    ];

    // ── valuation card ────────────────────────────────────────────
    pw.Widget valuationCard() {
      final netColor =
          valuationNet >= 0 ? _PdfColors.positive : _PdfColors.negative;
      return pw.Container(
        width: 200,
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          border: pw.Border(
            top: pw.BorderSide(color: _PdfColors.goldLight, width: 2),
          ),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              pdfVisualArabic('ملخص التقييم'),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                  font: boldFont,
                  fontSize: 8.5,
                  color: _PdfColors.goldMid),
            ),
            pw.SizedBox(height: 8),
            pw.Container(height: 2, color: _PdfColors.goldLight),
            pw.SizedBox(height: 8),
            _valRow('رصيد الذهب',
                '${periodClosingGold.toStringAsFixed(3)} جم', baseFont, boldFont),
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 5),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    pdfVisualArabic('سعر الجرام (${mainKarat}k)'),
                    textDirection: pw.TextDirection.ltr,
                    style: pw.TextStyle(
                        font: baseFont,
                        fontSize: 8,
                        color: pdf.PdfColor.fromHex('#444444')),
                  ),
                  buildCashAmt(
                    pdfVisualArabic((pricePerGram ?? 0).toStringAsFixed(2)),
                    font: boldFont,
                    fontSize: 8.5,
                    color: pdf.PdfColor.fromHex('#222222'),
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 8),
            pw.Container(height: 1, color: _PdfColors.goldLight),
            pw.SizedBox(height: 8),
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              children: [
                buildCashAmt(
                  pdfVisualArabic(commaFmt.format(valuationNet)),
                  font: boldFont,
                  fontSize: 13,
                  color: netColor,
                ),
                pw.Text(
                  pdfVisualArabic('صافي القيمة التقديرية'),
                  textDirection: pw.TextDirection.ltr,
                  style: pw.TextStyle(
                      font: boldFont, fontSize: 9, color: _PdfColors.dark),
                ),
              ],
            ),
          ],
        ),
      );
    }

    // ─────────────────────────────────────────────────────────────
    //  ASSEMBLE PDF DOCUMENT
    // ─────────────────────────────────────────────────────────────
    final doc = pw.Document();

    doc.addPage(
      pw.MultiPage(
        pageFormat: pageFormat,
        theme: theme,
        margin: const pw.EdgeInsets.symmetric(horizontal: 24, vertical: 20),

        // ── FOOTER ───────────────────────────────────────────────
        footer: (ctx) => pw.Directionality(
          textDirection: pw.TextDirection.rtl,
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              // A printed statement says what it leaves out (the owner,
              // 9 Oct 2026): it is not mistaken for every line of the books.
              if (statement.cancelledHidden &&
                  statement.cancelledCount + statement.correctionCount > 0) ...[
                pw.Text(
                  pdfVisualArabic(
                    'يستبعد هذا الكشف ${[
                      if (statement.cancelledCount > 0) '${statement.cancelledCount} من السندات الملغاة مع قيودها العكسية',
                      if (statement.correctionCount > 0) '${statement.correctionCount} من تصحيحات وسيلة الدفع',
                    ].join(' و')}، ولا يتغيّر بها الرصيد',
                  ),
                  textDirection: pw.TextDirection.ltr,
                  textAlign: pw.TextAlign.center,
                  style: pw.TextStyle(font: baseFont, fontSize: 7),
                ),
                pw.SizedBox(height: 3),
              ],
              pw.Container(height: 0.8, color: _PdfColors.borderLight),
              pw.SizedBox(height: 5),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(horizontal: 4),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: pw.CrossAxisAlignment.center,
                  children: [
                    // Left (visual in RTL): brand name
                    pw.Text(
                      '${branding.companyName} •',
                      textDirection: pw.TextDirection.rtl,
                      style: pw.TextStyle(
                          font: boldFont,
                          fontSize: 7.5,
                          color: _PdfColors.gold),
                    ),
                    // Center: page number + نهاية الكشف
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.RichText(
                          textDirection: pw.TextDirection.rtl,
                          text: pw.TextSpan(
                            children: [
                              pw.TextSpan(
                                text: 'الصفحة ',
                                style: pw.TextStyle(
                                    font: baseFont,
                                    fontSize: 7,
                                    color: _PdfColors.muted),
                              ),
                              pw.TextSpan(
                                text: ctx.pageNumber.toString(),
                                style: pw.TextStyle(
                                    font: boldFont,
                                    fontSize: 9.5,
                                    color: _PdfColors.gold),
                              ),
                              pw.TextSpan(
                                text: ' من ',
                                style: pw.TextStyle(
                                    font: baseFont,
                                    fontSize: 7,
                                    color: _PdfColors.muted),
                              ),
                              pw.TextSpan(
                                text: ctx.pagesCount.toString(),
                                style: pw.TextStyle(
                                    font: boldFont,
                                    fontSize: 9.5,
                                    color: _PdfColors.dark),
                              ),
                            ],
                          ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          ctx.pageNumber == ctx.pagesCount
                              ? pdfVisualArabic('نهاية الكشف')
                              : ' ',
                          textDirection: pw.TextDirection.ltr,
                          style: pw.TextStyle(
                              font: baseFont,
                              fontSize: 6.5,
                              color: _PdfColors.muted),
                        ),
                      ],
                    ),
                    // Right (visual in RTL): QR code
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.SizedBox(
                          width: 32,
                          height: 32,
                          child: qrData == null
                              ? pw.Container()
                              : pw.BarcodeWidget(
                                  barcode: qrBarcode,
                                  data: qrData,
                                  color: _PdfColors.gold,
                                ),
                        ),
                        pw.SizedBox(height: 2),
                        pw.Text(
                          pdfVisualArabic('رمز التحقق'),
                          textDirection: pw.TextDirection.ltr,
                          style: pw.TextStyle(
                              font: baseFont, fontSize: 5.5,
                              color: _PdfColors.muted),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // ── BODY ─────────────────────────────────────────────────
        build: (context) {
          pw.Widget rtl(pw.Widget child) => pw.Directionality(
                textDirection: pw.TextDirection.rtl,
                child: child,
              );

          final sections = <pw.Widget>[
            // ── TOP GOLD RULE ──
            goldRule(height: 4),
            pw.SizedBox(height: 8),

            // ── HEADER: RIGHT=logo+name+details | CENTER=title+QR | LEFT=meta ──
            pw.SizedBox(
              height: 80,
              child: pw.Stack(
                children: [

                  // ── LEFT ZONE: label-above-value meta chips ──
                  pw.Positioned(
                    top: 0,
                    left: 0,
                    child: pw.SizedBox(
                      width: 148,
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.start,
                        children: [
                          pw.Text(
                            pdfVisualArabic('رقم الكشف'),
                            textDirection: pw.TextDirection.ltr,
                            style: pw.TextStyle(
                                font: baseFont,
                                fontSize: 7,
                                color: _PdfColors.muted),
                          ),
                          pw.SizedBox(height: 1),
                          pw.Text(statementId,
                            style: pw.TextStyle(font: boldFont, fontSize: 8.5,
                                color: _PdfColors.dark)),
                          pw.SizedBox(height: 6),
                          pw.Text(
                            pdfVisualArabic('تاريخ الإصدار'),
                            textDirection: pw.TextDirection.ltr,
                            style: pw.TextStyle(
                                font: baseFont,
                                fontSize: 7,
                                color: _PdfColors.muted),
                          ),
                          pw.SizedBox(height: 1),
                          pw.Text(issuedAtText,
                            style: pw.TextStyle(font: boldFont, fontSize: 8.5,
                                color: _PdfColors.dark)),
                          pw.SizedBox(height: 6),
                          pw.Container(height: 0.6, color: _PdfColors.borderLight),
                          pw.SizedBox(height: 6),
                          pw.Text(
                            pdfVisualArabic('الحساب'),
                            textDirection: pw.TextDirection.ltr,
                            style: pw.TextStyle(
                                font: baseFont,
                                fontSize: 7,
                                color: _PdfColors.muted),
                          ),
                          pw.SizedBox(height: 1),
                          pw.Text(
                            pdfVisualArabic(accountName),
                            textDirection: pw.TextDirection.ltr,
                            style: pw.TextStyle(font: boldFont, fontSize: 8.5,
                                color: _PdfColors.dark),
                          ),
                        ],
                      ),
                    ),
                  ),

                  // ── CENTER ZONE: title only (QR moved to footer) ──
                  pw.Positioned(
                    top: 8,
                    left: 150,
                    right: 162,
                    child: pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.center,
                      children: [
                        pw.Text(
                          pdfVisualArabic('كشف حساب'),
                          textDirection: pw.TextDirection.ltr,
                          style: pw.TextStyle(
                              font: boldFont, fontSize: 22, color: _PdfColors.black),
                        ),
                        pw.SizedBox(height: 3),
                        pw.Text(
                          'Account Statement',
                          style: pw.TextStyle(
                              font: baseFont, fontSize: 8.5,
                              color: _PdfColors.muted, letterSpacing: 1.8),
                        ),
                      ],
                    ),
                  ),

                  // ── RIGHT ZONE: logo + name in same row, separator, details ──
                  pw.Positioned(
                    top: 0,
                    right: 0,
                    child: pw.SizedBox(
                      width: 160,
                      child: pw.Column(
                        crossAxisAlignment: pw.CrossAxisAlignment.end,
                        children: [
                          // Logo + company name side by side (RTL: name first, then logo)
                          pw.Directionality(
                            textDirection: pw.TextDirection.rtl,
                            child: pw.Row(
                              mainAxisSize: pw.MainAxisSize.min,
                              crossAxisAlignment: pw.CrossAxisAlignment.center,
                              children: [
                                if (branding.showCompanyLogo && logoImage != null)
                                  pw.Image(logoImage,
                                      width: 38, height: 38,
                                      fit: pw.BoxFit.contain),
                                if (branding.showCompanyLogo && logoImage != null)
                                  pw.SizedBox(width: 6),
                                if (branding.companyName.trim().isNotEmpty)
                                  pw.Text(
                                    branding.companyName.trim(),
                                    style: pw.TextStyle(font: boldFont,
                                        fontSize: 14, color: _PdfColors.black),
                                  ),
                              ],
                            ),
                          ),
                          pw.SizedBox(height: 5),
                          pw.Container(height: 0.6, color: _PdfColors.borderLight),
                          pw.SizedBox(height: 5),
                          // Details — value : label, right aligned
                          if (branding.companyCr.trim().isNotEmpty)
                            pw.Align(
                              alignment: pw.Alignment.centerRight,
                              child: _infoLine('سجل تجاري ',
                                  branding.companyCr.trim(), baseFont, _PdfColors.muted),
                            ),
                          if (branding.companyVat.trim().isNotEmpty)
                            pw.Align(
                              alignment: pw.Alignment.centerRight,
                              child: _infoLine('الرقم الضريبي',
                                  branding.companyVat.trim(), baseFont, _PdfColors.muted),
                            ),
                          if (branding.companyPhone.trim().isNotEmpty)
                            pw.Align(
                              alignment: pw.Alignment.centerRight,
                              child: _infoLine('الجوال',
                                  branding.companyPhone.trim(), baseFont, _PdfColors.muted),
                            ),
                          if (branding.companyAddress.trim().isNotEmpty)
                            pw.Align(
                              alignment: pw.Alignment.centerRight,
                              child: _infoLine('العنوان',
                                  branding.companyAddress.trim(), baseFont, _PdfColors.muted),
                            ),
                        ],
                      ),
                    ),
                  ),

                ],
              ),
            ),

            pw.SizedBox(height: 6),
            pw.Container(height: 0.8, color: _PdfColors.borderLight),

            pw.SizedBox(height: 10),

            // ── GOLD DIVIDER ──
            goldRule(height: 3),
            pw.SizedBox(height: 1),
            thinRule(),
            pw.SizedBox(height: 10),

            // ── CUSTOMER / SUPPLIER INFO BAR ──
            rtl(
              pw.Table(
                border: pw.TableBorder.all(
                    color: _PdfColors.borderLight, width: 0.7),
                columnWidths: {
                  0: const pw.FlexColumnWidth(2),
                  1: const pw.FlexColumnWidth(2),
                  2: const pw.FlexColumnWidth(3),
                },
                children: [
                  pw.TableRow(
                    decoration: pw.BoxDecoration(color: _PdfColors.goldBg),
                    children: [
                      _infoBarCell('الفترة',
                          dateRange == null ? 'جميع الفترات' : dateRangeText,
                          boldFont, baseFont),
                      _infoBarCell('رقم الحساب', accountId.toString(),
                          boldFont, baseFont),
                      _infoBarCell('العميل / المورد', accountName,
                          boldFont, baseFont),
                    ],
                  ),
                ],
              ),
            ),
            pw.SizedBox(height: 18),

            // ── BALANCE SUMMARY — six borderless luxury cards ──
            rtl(sectionHeading('ملخص الأرصدة')),
            pw.SizedBox(height: 8),
            rtl(
              pw.Row(
                children: [
                  pw.Expanded(child: balCell(
                    'مدين ذهب   جم',
                    totals.goldDebit.toStringAsFixed(3),
                    _PdfColors.positive,
                  )),
                  pw.SizedBox(width: 3),
                  pw.Expanded(child: balCell(
                    'دائن ذهب   جم',
                    totals.goldCredit.toStringAsFixed(3),
                    _PdfColors.negative,
                  )),
                  pw.SizedBox(width: 3),
                  pw.Expanded(child: balCell(
                    'رصيد الذهب   جم',
                    periodClosingGold.toStringAsFixed(3),
                    periodClosingGold < 0 ? _PdfColors.negative : _PdfColors.gold,
                    highlighted: true,
                  )),
                  pw.SizedBox(width: 8),
                  pw.Expanded(child: balCell(
                    'مدين نقد',
                    commaFmt.format(totals.cashDebit),
                    _PdfColors.positive,
                  )),
                  pw.SizedBox(width: 3),
                  pw.Expanded(child: balCell(
                    'دائن نقد',
                    commaFmt.format(totals.cashCredit),
                    _PdfColors.negative,
                  )),
                  pw.SizedBox(width: 3),
                  pw.Expanded(child: balCell(
                    'رصيد النقد',
                    commaFmt.format(periodClosingCash),
                    periodClosingCash < 0 ? _PdfColors.negative : _PdfColors.positive,
                    highlighted: true,
                  )),
                ],
              ),
            ),
            pw.SizedBox(height: 14),

            // ── FILTER STRIP — plain single line, no boxes ──
            rtl(
              pw.Container(
                padding:
                    const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                decoration: pw.BoxDecoration(
                  border: pw.Border(
                    bottom: pw.BorderSide(
                        color: _PdfColors.borderLight, width: 0.6),
                  ),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.end,
                  children: [
                    filterChip(label: 'الفترة', value: dateRange == null ? 'جميع الفترات' : dateRangeText),
                    pw.SizedBox(width: 4),
                    pw.Text('  |  ', style: pw.TextStyle(font: baseFont, fontSize: 7.5, color: _PdfColors.borderLight)),
                    pw.SizedBox(width: 4),
                    filterChip(label: 'العيار', value: '$mainKarat'),
                    pw.SizedBox(width: 4),
                    pw.Text('  |  ', style: pw.TextStyle(font: baseFont, fontSize: 7.5, color: _PdfColors.borderLight)),
                    pw.SizedBox(width: 4),
                    filterChip(label: 'العرض', value: viewModeLabel),
                    if (goldPriceChipRendered) ...[
                      pw.SizedBox(width: 4),
                      pw.Text('  |  ', style: pw.TextStyle(font: baseFont, fontSize: 7.5, color: _PdfColors.borderLight)),
                      pw.SizedBox(width: 4),
                      filterChip(label: 'سعر الجرام', value: pricePerGram!.toStringAsFixed(2)),
                    ],
                  ],
                ),
              ),
            ),
            pw.SizedBox(height: 12),

            // ── TRANSACTIONS TABLE ──
            rtl(sectionHeading('تفاصيل الحركات')),
            pw.SizedBox(height: 5),
            rtl(
              pw.TableHelper.fromTextArray(
                headers: columns.map((c) {
                  final cell =
                      headerCell(c.header, isDesc: c.key == descKey);
                  return pw.Container(color: _PdfColors.goldBg, child: cell);
                }).toList(),
                data: allRows,
                border: pw.TableBorder(
                  bottom: pw.BorderSide(color: _PdfColors.borderLight, width: 0.5),
                  horizontalInside: pw.BorderSide(color: _PdfColors.borderLight, width: 0.4),
                ),
                cellPadding: pw.EdgeInsets.zero,
                columnWidths: colWidths,
              ),
            ),

            // ── VALUATION + NOTES ──
            if (valuationBannerRendered) ...[
              pw.SizedBox(height: 9),
              rtl(
                pw.Row(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    valuationCard(),
                    pw.SizedBox(width: 12),
                    pw.Expanded(
                      child: pw.Container(
                        padding: const pw.EdgeInsets.all(12),
                        decoration: pw.BoxDecoration(
                          border: pw.Border(
                            top: pw.BorderSide(
                                color: _PdfColors.borderLight, width: 1.5),
                          ),
                        ),
                        child: pw.Directionality(
                          textDirection: pw.TextDirection.rtl,
                          child: pw.Column(
                            crossAxisAlignment: pw.CrossAxisAlignment.start,
                            children: [
                              pw.Text(
                                pdfVisualArabic('ملاحظة'),
                                textDirection: pw.TextDirection.ltr,
                                style: pw.TextStyle(
                                    font: boldFont,
                                    fontSize: 9,
                                    color: _PdfColors.dark),
                              ),
                              pw.SizedBox(height: 8),
                              pw.Container(
                                  height: 0.5,
                                  color: _PdfColors.borderLight),
                              pw.SizedBox(height: 8),
                              pw.Text(
                                pdfVisualArabic(digitalDocumentFooterText),
                                textDirection: pw.TextDirection.ltr,
                                style: pw.TextStyle(
                                    font: baseFont,
                                    fontSize: 8,
                                    color: _PdfColors.muted),
                              ),
                              pw.SizedBox(height: 6),
                              pw.Text(
                                pdfVisualArabic(
                                  'يمكن التحقق من صحة الكشف عبر رمز QR\nأو التواصل مع المكتب مباشرة',
                                ),
                                textDirection: pw.TextDirection.ltr,
                                style: pw.TextStyle(
                                    font: baseFont,
                                    fontSize: 7.5,
                                    color: _PdfColors.muted),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            pw.SizedBox(height: 8),

            // ── BOTTOM GOLD RULE ──
            thinRule(),
            pw.SizedBox(height: 2),
            goldRule(height: 3),
          ];

          return sections;
        },
      ),
    );

    return doc.save();
  }

  // ── small private helpers ─────────────────────────────────────

  static pw.Widget _infoLine(
      String label, String value, pw.Font font, pdf.PdfColor color) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 3),
      child: pw.Row(
        mainAxisSize: pw.MainAxisSize.min,
        children: [
          pw.Text(
            pdfVisualArabic(value),
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(font: font, fontSize: 8, color: color),
          ),
          pw.SizedBox(width: 6),
          pw.Text(
            pdfVisualArabic('$label:'),
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
                font: font,
                fontSize: 8,
                color: pdf.PdfColor.fromHex('#444444')),
          ),
        ],
      ),
    );
  }

  static pw.Widget _valRow(
      String label, String value, pw.Font base, pw.Font bold) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 5),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
            pw.Text(pdfVisualArabic(label),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                  font: base,
                  fontSize: 8,
                  color: pdf.PdfColor.fromHex('#444444'))),
            pw.Text(pdfVisualArabic(value),
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(
                  font: bold,
                  fontSize: 8.5,
                  color: pdf.PdfColor.fromHex('#222222'))),
        ],
      ),
    );
  }

  static pw.Widget _infoBarCell(
      String label, String value, pw.Font bold, pw.Font base) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            pdfVisualArabic(label),
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
                font: base,
                fontSize: 7,
                color: pdf.PdfColor.fromHex('#444444')),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            pdfVisualArabic(value),
            textDirection: pw.TextDirection.ltr,
            style: pw.TextStyle(
                font: bold,
                fontSize: 9,
                color: pdf.PdfColor.fromHex('#222222')),
          ),
        ],
      ),
    );
  }
}
