import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';

/// شاشة معاينة وطباعة القيود اليومية
class JournalEntryPrintScreen extends StatefulWidget {
  final Map<String, dynamic> journalEntry;
  final bool isArabic;
  final Map<String, dynamic>? printSettings;

  const JournalEntryPrintScreen({
    super.key,
    required this.journalEntry,
    this.isArabic = true,
    this.printSettings,
  });

  @override
  State<JournalEntryPrintScreen> createState() =>
      _JournalEntryPrintScreenState();
}

class _JournalEntryPrintScreenState extends State<JournalEntryPrintScreen> {
  bool _isGenerating = false;

  late bool _showLogo;
  late bool _hideGoldColumnsWhenZero;
  late bool _showKaratBreakdown;
  late String _paperSize;
  late String _orientation;

  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
  }

  void _loadPrintSettings() {
    final settings = widget.printSettings ?? {};
    _showLogo = settings['showLogo'] ?? true;
    _hideGoldColumnsWhenZero = settings['hideGoldColumnsWhenZero'] ?? true;
    _showKaratBreakdown = settings['showKaratBreakdown'] ?? true;
    _paperSize = settings['paperSize'] ?? 'A4';
    _orientation = settings['orientation'] ?? 'portrait';
  }

  String _fmtDate(dynamic raw) {
    if (raw == null) return '';
    final s = raw.toString();
    if (s.isEmpty) return '';
    try {
      final dt = DateTime.tryParse(s);
      if (dt == null) return s;
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (_) {
      return s;
    }
  }

  double _num(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  ({
    double debit18,
    double debit21,
    double debit22,
    double debit24,
    double credit18,
    double credit21,
    double credit22,
    double credit24,
  }) _karatAmounts(dynamic raw) {
    final m = (raw is Map)
        ? raw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    // Support both keys used across endpoints/versions.
    double get(String primary, String fallback) => _num(m[primary] ?? m[fallback]);

    return (
      debit18: get('debit_18k', 'debit_gold_18k'),
      debit21: get('debit_21k', 'debit_gold_21k'),
      debit22: get('debit_22k', 'debit_gold_22k'),
      debit24: get('debit_24k', 'debit_gold_24k'),
      credit18: get('credit_18k', 'credit_gold_18k'),
      credit21: get('credit_21k', 'credit_gold_21k'),
      credit22: get('credit_22k', 'credit_gold_22k'),
      credit24: get('credit_24k', 'credit_gold_24k'),
    );
  }

  ({
    String accountNumber,
    String accountName,
    double cashDebit,
    double cashCredit,
    double goldDebit,
    double goldCredit,
    String weightType,
    String lineDescription,
  }) _normalizeLine(dynamic raw) {
    final m = (raw is Map)
        ? raw.map((k, v) => MapEntry(k.toString(), v))
        : <String, dynamic>{};

    String accountName = '';
    String accountNumber = '';

    final account = m['account'];
    if (account is Map) {
      final an = account['name']?.toString();
      final num = account['account_number']?.toString();
      if (an != null) accountName = an;
      if (num != null) accountNumber = num;
    }

    accountName = (m['account_name']?.toString() ?? accountName).trim();
    accountNumber = (m['account_number']?.toString() ?? accountNumber).trim();

    final cashDebit = _num(m['cash_debit'] ?? m['debit_cash']);
    final cashCredit = _num(m['cash_credit'] ?? m['credit_cash']);

    final debitWeight = _num(m['debit_weight'] ?? m['debit_gold']);
    final creditWeight = _num(m['credit_weight'] ?? m['credit_gold']);

    // Fallback to per-karat totals if weight-equivalent is missing.
    final debitKaratSum =
        _num(m['debit_18k']) + _num(m['debit_21k']) + _num(m['debit_22k']) + _num(m['debit_24k']);
    final creditKaratSum =
        _num(m['credit_18k']) + _num(m['credit_21k']) + _num(m['credit_22k']) + _num(m['credit_24k']);

    final goldDebit = (debitWeight.abs() > 0.0000001) ? debitWeight : debitKaratSum;
    final goldCredit = (creditWeight.abs() > 0.0000001) ? creditWeight : creditKaratSum;

    final weightType = (m['weight_type']?.toString() ?? '').trim();
    final lineDescription = (m['description']?.toString() ?? '').trim();

    return (
      accountNumber: accountNumber,
      accountName: accountName,
      cashDebit: cashDebit,
      cashCredit: cashCredit,
      goldDebit: goldDebit,
      goldCredit: goldCredit,
      weightType: weightType,
      lineDescription: lineDescription,
    );
  }

  ({
    double cashDebit,
    double cashCredit,
    double goldDebit,
    double goldCredit,
  }) _computeTotals(List<dynamic> lines) {
    double cashDebit = 0;
    double cashCredit = 0;
    double goldDebit = 0;
    double goldCredit = 0;

    for (final raw in lines) {
      final n = _normalizeLine(raw);
      cashDebit += n.cashDebit;
      cashCredit += n.cashCredit;
      goldDebit += n.goldDebit;
      goldCredit += n.goldCredit;
    }

    return (
      cashDebit: cashDebit,
      cashCredit: cashCredit,
      goldDebit: goldDebit,
      goldCredit: goldCredit,
    );
  }

  ({
    double debit18,
    double debit21,
    double debit22,
    double debit24,
    double credit18,
    double credit21,
    double credit22,
    double credit24,
  }) _computeKaratTotals(List<dynamic> lines) {
    double debit18 = 0;
    double debit21 = 0;
    double debit22 = 0;
    double debit24 = 0;
    double credit18 = 0;
    double credit21 = 0;
    double credit22 = 0;
    double credit24 = 0;

    for (final raw in lines) {
      final k = _karatAmounts(raw);
      debit18 += k.debit18;
      debit21 += k.debit21;
      debit22 += k.debit22;
      debit24 += k.debit24;
      credit18 += k.credit18;
      credit21 += k.credit21;
      credit22 += k.credit22;
      credit24 += k.credit24;
    }

    return (
      debit18: debit18,
      debit21: debit21,
      debit22: debit22,
      debit24: debit24,
      credit18: credit18,
      credit21: credit21,
      credit22: credit22,
      credit24: credit24,
    );
  }

  bool _hasAnyKaratTotals(({
    double debit18,
    double debit21,
    double debit22,
    double debit24,
    double credit18,
    double credit21,
    double credit22,
    double credit24,
  }) t) {
    const eps = 0.0000001;
    return (t.debit18.abs() > eps) ||
        (t.debit21.abs() > eps) ||
        (t.debit22.abs() > eps) ||
        (t.debit24.abs() > eps) ||
        (t.credit18.abs() > eps) ||
        (t.credit21.abs() > eps) ||
        (t.credit22.abs() > eps) ||
        (t.credit24.abs() > eps);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'طباعة قيد يومي' : 'Print Journal Entry'),
        backgroundColor: const Color(0xFFD4AF37),
        actions: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _downloadPdf,
            tooltip: widget.isArabic ? 'تحميل PDF' : 'Download PDF',
          ),
        ],
      ),
      body: _isGenerating
          ? const Center(child: CircularProgressIndicator())
          : kIsWeb
          ? _buildWebPreview()
          : PdfPreview(
              build: (format) => _generatePdf(format),
              canChangePageFormat: true,
              allowPrinting: true,
              allowSharing: true,
              initialPageFormat: _getPdfPageFormat(),
              pdfFileName:
                  'journal_entry_${widget.journalEntry['id']}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
            ),
    );
  }

  Widget _buildWebPreview() {
    final entry = widget.journalEntry;
    final lines = (entry['lines'] as List<dynamic>?) ?? [];
    final entryNumber = (entry['entry_number']?.toString().trim().isNotEmpty ?? false)
        ? entry['entry_number'].toString()
        : '#${entry['id']}';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.receipt_long, size: 80, color: Color(0xFFD4AF37)),
            const SizedBox(height: 24),
            Text(
              widget.isArabic
                  ? 'قيد يومي رقم $entryNumber'
                  : 'Journal Entry $entryNumber',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              widget.isArabic
                  ? 'اضغط على زر التحميل أعلاه لحفظ القيد كـ PDF'
                  : 'Click the download button above to save the entry as PDF',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _downloadPdf,
              icon: const Icon(Icons.download),
              label: Text(
                widget.isArabic ? 'تحميل القيد PDF' : 'Download Entry PDF',
                style: const TextStyle(fontSize: 18),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFD4AF37),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 16,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 32),
            _buildJournalEntrySummary(lines),
          ],
        ),
      ),
    );
  }

  Widget _buildJournalEntrySummary(List<dynamic> lines) {
    final entry = widget.journalEntry;
    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');

    final totals = _computeTotals(lines);
    final totalDebitCash = totals.cashDebit;
    final totalCreditCash = totals.cashCredit;
    final totalDebitGold = totals.goldDebit;
    final totalCreditGold = totals.goldCredit;

    final hasAnyGold = (totalDebitGold.abs() > 0.0000001) || (totalCreditGold.abs() > 0.0000001);
    final karatTotals = _computeKaratTotals(lines);
    final hasKaratBreakdown = _showKaratBreakdown && _hasAnyKaratTotals(karatTotals);

    final entryNumber = (entry['entry_number']?.toString().trim().isNotEmpty ?? false)
        ? entry['entry_number'].toString()
        : '#${entry['id']}';
    final createdBy = entry['created_by']?.toString().trim();
    final isPosted = entry['is_posted'] == true;
    final postedBy = entry['posted_by']?.toString().trim();

    final cashDiff = (totalDebitCash - totalCreditCash).abs();
    final goldDiff = (totalDebitGold - totalCreditGold).abs();
    final isCashBalanced = cashDiff <= 0.01;
    final isGoldBalanced = goldDiff <= 0.0005;

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.receipt_long, color: Color(0xFFD4AF37)),
                const SizedBox(width: 12),
                Text(
                  widget.isArabic
                      ? 'ملخص القيد اليومي'
                      : 'Journal Entry Summary',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _buildInfoRow(
              widget.isArabic ? 'رقم القيد' : 'Entry No.',
              entryNumber,
            ),
            _buildInfoRow(
              widget.isArabic ? 'التاريخ' : 'Date',
              _fmtDate(entry['date']),
            ),
            _buildInfoRow(
              widget.isArabic ? 'نوع القيد' : 'Entry Type',
              entry['entry_type'] ?? '',
            ),
            if (createdBy != null && createdBy.isNotEmpty)
              _buildInfoRow(
                widget.isArabic ? 'أنشئ بواسطة' : 'Created By',
                createdBy,
              ),
            _buildInfoRow(
              widget.isArabic ? 'الترحيل' : 'Posting',
              widget.isArabic
                  ? (isPosted ? 'مُرحّل' : 'غير مُرحّل')
                  : (isPosted ? 'Posted' : 'Not posted'),
            ),
            if (postedBy != null && postedBy.isNotEmpty)
              _buildInfoRow(
                widget.isArabic ? 'رُحّل بواسطة' : 'Posted By',
                postedBy,
              ),
            _buildInfoRow(
              widget.isArabic ? 'عدد الحسابات' : 'Number of Lines',
              '${lines.length}',
            ),
            const Divider(height: 16),
            if (!isCashBalanced || !isGoldBalanced)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  widget.isArabic
                      ? '⚠️ تنبيه: القيد غير متوازن (قد يكون بسبب التقريب)'
                      : '⚠️ Warning: Entry is not balanced (may be rounding)',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.red,
                  ),
                ),
              ),
            Text(
              widget.isArabic ? 'الإجماليات:' : 'Totals:',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
            const SizedBox(height: 8),
            _buildInfoRow(
              widget.isArabic ? 'إجمالي المدين (نقداً)' : 'Total Debit (Cash)',
              '${currencyFormat.format(totalDebitCash)} ${widget.isArabic ? 'ريال' : 'SAR'}',
              isAmount: true,
            ),
            _buildInfoRow(
              widget.isArabic ? 'إجمالي الدائن (نقداً)' : 'Total Credit (Cash)',
              '${currencyFormat.format(totalCreditCash)} ${widget.isArabic ? 'ريال' : 'SAR'}',
              isAmount: true,
            ),
            if (totalDebitGold > 0 || totalCreditGold > 0) ...[
              _buildInfoRow(
                widget.isArabic ? 'إجمالي المدين (ذهب)' : 'Total Debit (Gold)',
                '${goldFormat.format(totalDebitGold)} ${widget.isArabic ? 'جرام' : 'g'}',
                isAmount: true,
              ),
              _buildInfoRow(
                widget.isArabic ? 'إجمالي الدائن (ذهب)' : 'Total Credit (Gold)',
                '${goldFormat.format(totalCreditGold)} ${widget.isArabic ? 'جرام' : 'g'}',
                isAmount: true,
              ),
            ],
            if (hasKaratBreakdown && hasAnyGold) ...[
              const SizedBox(height: 6),
              Text(
                widget.isArabic ? 'تفصيل الأعيرة (ذهب):' : 'Gold Karat Breakdown:',
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              ),
              const SizedBox(height: 6),
              if (karatTotals.debit18.abs() > 0.0000001 || karatTotals.credit18.abs() > 0.0000001)
                _buildInfoRow(
                  widget.isArabic ? 'عيار 18' : '18K',
                  '${widget.isArabic ? 'مدين' : 'Dr'} ${goldFormat.format(karatTotals.debit18)} | ${widget.isArabic ? 'دائن' : 'Cr'} ${goldFormat.format(karatTotals.credit18)}',
                ),
              if (karatTotals.debit21.abs() > 0.0000001 || karatTotals.credit21.abs() > 0.0000001)
                _buildInfoRow(
                  widget.isArabic ? 'عيار 21' : '21K',
                  '${widget.isArabic ? 'مدين' : 'Dr'} ${goldFormat.format(karatTotals.debit21)} | ${widget.isArabic ? 'دائن' : 'Cr'} ${goldFormat.format(karatTotals.credit21)}',
                ),
              if (karatTotals.debit22.abs() > 0.0000001 || karatTotals.credit22.abs() > 0.0000001)
                _buildInfoRow(
                  widget.isArabic ? 'عيار 22' : '22K',
                  '${widget.isArabic ? 'مدين' : 'Dr'} ${goldFormat.format(karatTotals.debit22)} | ${widget.isArabic ? 'دائن' : 'Cr'} ${goldFormat.format(karatTotals.credit22)}',
                ),
              if (karatTotals.debit24.abs() > 0.0000001 || karatTotals.credit24.abs() > 0.0000001)
                _buildInfoRow(
                  widget.isArabic ? 'عيار 24' : '24K',
                  '${widget.isArabic ? 'مدين' : 'Dr'} ${goldFormat.format(karatTotals.debit24)} | ${widget.isArabic ? 'دائن' : 'Cr'} ${goldFormat.format(karatTotals.credit24)}',
                ),
            ],
            if (entry['description'] != null &&
                entry['description'].toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.isArabic ? 'البيان:' : 'Description:',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(entry['description'].toString()),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {bool isAmount = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: isAmount ? FontWeight.bold : FontWeight.normal,
              fontSize: isAmount ? 16 : 14,
              color: isAmount ? Colors.black : Colors.grey.shade800,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _downloadPdf() async {
    try {
      setState(() => _isGenerating = true);
      final pdf = await _generatePdf(_getPdfPageFormat());

      await Printing.layoutPdf(
        onLayout: (_) => pdf,
        name: 'journal_entry_${widget.journalEntry['id']}.pdf',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? '✓ تم تحميل القيد بنجاح'
                  : '✓ Entry downloaded successfully',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${widget.isArabic ? 'خطأ' : 'Error'}: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isGenerating = false);
      }
    }
  }

  PdfPageFormat _getPdfPageFormat() {
    PdfPageFormat base;
    switch (_paperSize) {
      case 'A5':
        base = PdfPageFormat.a5;
        break;
      case 'Letter':
        base = PdfPageFormat.letter;
        break;
      case 'Thermal':
        // Thermal is typically portrait only.
        return const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity);
      default:
        base = PdfPageFormat.a4;
    }

    if (_orientation == 'landscape') return base.landscape;
    return base;
  }

  Future<Uint8List> _generatePdf(PdfPageFormat format) async {
    final pdf = pw.Document();
    final entry = widget.journalEntry;
    final lines = (entry['lines'] as List<dynamic>?) ?? [];

    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');

    final totals = _computeTotals(lines);
    final totalDebitCash = totals.cashDebit;
    final totalCreditCash = totals.cashCredit;
    final totalDebitGold = totals.goldDebit;
    final totalCreditGold = totals.goldCredit;

    final hasAnyGold = (totalDebitGold.abs() > 0.0000001) || (totalCreditGold.abs() > 0.0000001);
    final showGoldColumns = !_hideGoldColumnsWhenZero || hasAnyGold;

    final karatTotals = _computeKaratTotals(lines);
    final hasKaratBreakdown = _showKaratBreakdown && showGoldColumns && _hasAnyKaratTotals(karatTotals);

    final cashDiff = (totalDebitCash - totalCreditCash).abs();
    final goldDiff = (totalDebitGold - totalCreditGold).abs();
    final isCashBalanced = cashDiff <= 0.01;
    final isGoldBalanced = goldDiff <= 0.0005;

    final entryNumber =
      (entry['entry_number']?.toString().trim().isNotEmpty ?? false)
        ? entry['entry_number'].toString()
        : '#${entry['id']}';
    final createdBy = entry['created_by']?.toString().trim();
    final isPosted = entry['is_posted'] == true;
    final postedBy = entry['posted_by']?.toString().trim();
    final referenceType = entry['reference_type']?.toString().trim();
    final referenceNumber = entry['reference_number']?.toString().trim();

    pdf.addPage(
      pw.MultiPage(
        pageFormat: format,
        textDirection: widget.isArabic
            ? pw.TextDirection.rtl
            : pw.TextDirection.ltr,
        theme: pw.ThemeData.withFont(
          base: await PdfGoogleFonts.cairoRegular(),
          bold: await PdfGoogleFonts.cairoBold(),
        ),
        footer: (context) => pw.Center(
          child: pw.Text(
            '${widget.isArabic ? 'تاريخ الطباعة' : 'Printed on'}: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (context) {
          pw.Widget header() {
            return pw.Container(
              padding: const pw.EdgeInsets.all(18),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#FFF9E6'),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        widget.isArabic ? 'قيد يومي' : 'Journal Entry',
                        style: pw.TextStyle(
                          fontSize: 22,
                          fontWeight: pw.FontWeight.bold,
                          color: PdfColor.fromHex('#D4AF37'),
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(entryNumber, style: const pw.TextStyle(fontSize: 12)),
                    ],
                  ),
                  if (_showLogo)
                    pw.Container(
                      width: 56,
                      height: 56,
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#D4AF37'),
                        shape: pw.BoxShape.circle,
                      ),
                      child: pw.Center(
                        child: pw.Text(
                          widget.isArabic ? 'خالد' : 'KHALED',
                          style: pw.TextStyle(
                            color: PdfColors.white,
                            fontWeight: pw.FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          }

          final infoChildren = <pw.Widget>[
            _buildPdfRow(widget.isArabic ? 'التاريخ' : 'Date', _fmtDate(entry['date'])),
            _buildPdfRow(widget.isArabic ? 'نوع القيد' : 'Entry Type', (entry['entry_type'] ?? '').toString()),
            _buildPdfRow(
              widget.isArabic ? 'الترحيل' : 'Posting',
              widget.isArabic
                  ? (isPosted ? 'مُرحّل' : 'غير مُرحّل')
                  : (isPosted ? 'Posted' : 'Not posted'),
            ),
            if (createdBy != null && createdBy.isNotEmpty)
              _buildPdfRow(widget.isArabic ? 'أنشئ بواسطة' : 'Created By', createdBy),
            if (postedBy != null && postedBy.isNotEmpty)
              _buildPdfRow(widget.isArabic ? 'رُحّل بواسطة' : 'Posted By', postedBy),
            if (referenceType != null && referenceType.isNotEmpty)
              _buildPdfRow(widget.isArabic ? 'نوع المرجع' : 'Reference Type', referenceType),
            if (referenceNumber != null && referenceNumber.isNotEmpty)
              _buildPdfRow(widget.isArabic ? 'رقم المرجع' : 'Reference No.', referenceNumber),
          ];

          if (entry['description'] != null && entry['description'].toString().trim().isNotEmpty) {
            infoChildren.add(
              pw.Container(
                margin: const pw.EdgeInsets.only(top: 8),
                padding: const pw.EdgeInsets.all(8),
                decoration: pw.BoxDecoration(
                  color: PdfColor.fromHex('#F5F5F5'),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(6)),
                ),
                child: pw.Text(
                  '${widget.isArabic ? 'البيان' : 'Description'}: ${entry['description'].toString()}',
                  style: const pw.TextStyle(fontSize: 10),
                ),
              ),
            );
          }

          pw.Widget balanceBanner() {
            if (isCashBalanced && (totalDebitGold == 0 && totalCreditGold == 0 || isGoldBalanced)) {
              return pw.Container();
            }
            return pw.Container(
              padding: const pw.EdgeInsets.all(10),
              decoration: pw.BoxDecoration(
                color: PdfColor.fromHex('#FFEBEE'),
                border: pw.Border.all(color: PdfColor.fromHex('#C62828')),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Text(
                widget.isArabic
                    ? '⚠️ تنبيه: القيد غير متوازن (قد يكون بسبب التقريب)'
                    : '⚠️ Warning: Entry is not balanced (may be rounding)'
                ,
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromHex('#C62828'),
                ),
              ),
            );
          }

          pw.Widget linesTable() {
            final headerBg = PdfColor.fromHex('#D4AF37');

            final normalized = lines.map(_normalizeLine).toList();

            pw.Widget headerCell(String text, {pw.TextAlign align = pw.TextAlign.center}) {
              return pw.Text(
                text,
                style: pw.TextStyle(
                  color: PdfColors.white,
                  fontWeight: pw.FontWeight.bold,
                  fontSize: 10,
                ),
                textAlign: align,
              );
            }

            pw.Widget cell(String text, {pw.TextAlign align = pw.TextAlign.center, bool bold = false}) {
              return pw.Text(
                text,
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
                ),
                textAlign: align,
              );
            }

            String moneyOrDash(double v) => v.abs() > 0.000001 ? currencyFormat.format(v) : '—';
            String goldOrDash(double v) => v.abs() > 0.0000001 ? goldFormat.format(v) : '—';

            final accountFlex = showGoldColumns ? 4 : 6;
            final cashFlex = 2;
            final goldFlex = 2;

            return pw.Container(
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Column(
                children: [
                  pw.Container(
                    padding: const pw.EdgeInsets.all(10),
                    decoration: pw.BoxDecoration(
                      color: headerBg,
                      borderRadius: const pw.BorderRadius.only(
                        topLeft: pw.Radius.circular(8),
                        topRight: pw.Radius.circular(8),
                      ),
                    ),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          flex: accountFlex,
                          child: headerCell(widget.isArabic ? 'الحساب (الكود - الاسم)' : 'Account (Code - Name)', align: pw.TextAlign.left),
                        ),
                        pw.Expanded(flex: cashFlex, child: headerCell(widget.isArabic ? 'مدين' : 'Debit')),
                        pw.Expanded(flex: cashFlex, child: headerCell(widget.isArabic ? 'دائن' : 'Credit')),
                        if (showGoldColumns) ...[
                          pw.Expanded(flex: goldFlex, child: headerCell(widget.isArabic ? 'مدين ذهب' : 'Gold Dr')),
                          pw.Expanded(flex: goldFlex, child: headerCell(widget.isArabic ? 'دائن ذهب' : 'Gold Cr')),
                        ],
                      ],
                    ),
                  ),
                  ...normalized.asMap().entries.map((e) {
                    final index = e.key;
                    final line = e.value;
                    final isEven = index % 2 == 0;

                    final accountDisplay = (line.accountNumber.isNotEmpty)
                        ? '${line.accountNumber} - ${line.accountName}'
                        : line.accountName;

                    return pw.Container(
                      padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: pw.BoxDecoration(
                        color: isEven ? PdfColors.white : PdfColor.fromHex('#F9F9F9'),
                      ),
                      child: pw.Column(
                        children: [
                          pw.Row(
                            children: [
                              pw.Expanded(
                                flex: accountFlex,
                                child: cell(accountDisplay, align: pw.TextAlign.left),
                              ),
                              pw.Expanded(flex: cashFlex, child: cell(moneyOrDash(line.cashDebit))),
                              pw.Expanded(flex: cashFlex, child: cell(moneyOrDash(line.cashCredit))),
                              if (showGoldColumns) ...[
                                pw.Expanded(flex: goldFlex, child: cell(goldOrDash(line.goldDebit))),
                                pw.Expanded(flex: goldFlex, child: cell(goldOrDash(line.goldCredit))),
                              ],
                            ],
                          ),
                          if (line.lineDescription.isNotEmpty || line.weightType.isNotEmpty)
                            pw.Padding(
                              padding: const pw.EdgeInsets.only(top: 4),
                              child: pw.Row(
                                children: [
                                  pw.Expanded(
                                    child: pw.Text(
                                      [
                                        if (line.lineDescription.isNotEmpty) line.lineDescription,
                                        if (line.weightType.isNotEmpty) '${widget.isArabic ? 'نوع الوزن' : 'Weight'}: ${line.weightType}',
                                      ].join(' | '),
                                      style: pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
                                      textAlign: pw.TextAlign.left,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    );
                  }),
                  pw.Container(
                    padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    decoration: pw.BoxDecoration(
                      color: PdfColor.fromHex('#FFF9E6'),
                      border: pw.Border(
                        top: pw.BorderSide(color: PdfColors.grey400, width: 2),
                      ),
                    ),
                    child: pw.Row(
                      children: [
                        pw.Expanded(
                          flex: accountFlex,
                          child: cell(widget.isArabic ? 'الإجمالي' : 'Total', align: pw.TextAlign.left, bold: true),
                        ),
                        pw.Expanded(flex: cashFlex, child: cell(currencyFormat.format(totalDebitCash), bold: true)),
                        pw.Expanded(flex: cashFlex, child: cell(currencyFormat.format(totalCreditCash), bold: true)),
                        if (showGoldColumns) ...[
                          pw.Expanded(flex: goldFlex, child: cell(goldFormat.format(totalDebitGold), bold: true)),
                          pw.Expanded(flex: goldFlex, child: cell(goldFormat.format(totalCreditGold), bold: true)),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          pw.Widget karatBreakdownSection() {
            if (!hasKaratBreakdown) return pw.Container();

            pw.Widget row(String label, double dr, double cr) {
              return pw.Padding(
                padding: const pw.EdgeInsets.symmetric(vertical: 2),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
                    pw.Text(
                      '${widget.isArabic ? 'مدين' : 'Dr'} ${goldFormat.format(dr)} | ${widget.isArabic ? 'دائن' : 'Cr'} ${goldFormat.format(cr)}',
                      style: const pw.TextStyle(fontSize: 11),
                    ),
                  ],
                ),
              );
            }

            final items = <pw.Widget>[];
            if (karatTotals.debit18.abs() > 0.0000001 || karatTotals.credit18.abs() > 0.0000001) {
              items.add(row(widget.isArabic ? 'عيار 18' : '18K', karatTotals.debit18, karatTotals.credit18));
            }
            if (karatTotals.debit21.abs() > 0.0000001 || karatTotals.credit21.abs() > 0.0000001) {
              items.add(row(widget.isArabic ? 'عيار 21' : '21K', karatTotals.debit21, karatTotals.credit21));
            }
            if (karatTotals.debit22.abs() > 0.0000001 || karatTotals.credit22.abs() > 0.0000001) {
              items.add(row(widget.isArabic ? 'عيار 22' : '22K', karatTotals.debit22, karatTotals.credit22));
            }
            if (karatTotals.debit24.abs() > 0.0000001 || karatTotals.credit24.abs() > 0.0000001) {
              items.add(row(widget.isArabic ? 'عيار 24' : '24K', karatTotals.debit24, karatTotals.credit24));
            }

            if (items.isEmpty) return pw.Container();
            return _buildPdfSection(widget.isArabic ? 'تفصيل الأعيرة (ذهب)' : 'Gold Karat Breakdown', items);
          }

          return [
            header(),
            pw.SizedBox(height: 14),
            balanceBanner(),
            if (!isCashBalanced || !isGoldBalanced) pw.SizedBox(height: 10),
            _buildPdfSection(widget.isArabic ? 'معلومات القيد' : 'Entry Information', infoChildren),
            if (hasKaratBreakdown) pw.SizedBox(height: 12),
            karatBreakdownSection(),
            pw.SizedBox(height: 14),
            linesTable(),
            pw.SizedBox(height: 18),
            pw.Container(
              padding: const pw.EdgeInsets.all(16),
              decoration: pw.BoxDecoration(
                border: pw.Border.all(color: PdfColors.grey300),
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  _buildSignatureBox(widget.isArabic ? 'المحاسب' : 'Accountant'),
                  _buildSignatureBox(widget.isArabic ? 'المراجع' : 'Reviewer'),
                  _buildSignatureBox(widget.isArabic ? 'المدير' : 'Manager'),
                ],
              ),
            ),
          ];
        },
      ),
    );

    return pdf.save();
  }

  pw.Widget _buildPdfSection(String title, List<pw.Widget> children) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(15),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            title,
            style: pw.TextStyle(
              fontSize: 14,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#D4AF37'),
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Divider(color: PdfColors.grey300),
          pw.SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }

  pw.Widget _buildPdfRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 12)),
          pw.Text(value, style: const pw.TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  pw.Widget _buildSignatureBox(String label) {
    return pw.Container(
      width: 140,
      child: pw.Column(
        children: [
          pw.Container(
            height: 60,
            decoration: pw.BoxDecoration(
              border: pw.Border(
                bottom: pw.BorderSide(color: PdfColors.grey400),
              ),
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
