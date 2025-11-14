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
  State<JournalEntryPrintScreen> createState() => _JournalEntryPrintScreenState();
}

class _JournalEntryPrintScreenState extends State<JournalEntryPrintScreen> {
  bool _isGenerating = false;

  late bool _showLogo;
  late String _paperSize;

  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
  }

  void _loadPrintSettings() {
    final settings = widget.printSettings ?? {};
    _showLogo = settings['showLogo'] ?? true;
    _paperSize = settings['paperSize'] ?? 'A4';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isArabic ? 'طباعة قيد يومي' : 'Print Journal Entry',
        ),
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
    
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.receipt_long,
              size: 80,
              color: Color(0xFFD4AF37),
            ),
            const SizedBox(height: 24),
            Text(
              widget.isArabic
                  ? 'قيد يومي رقم #${entry['id']}'
                  : 'Journal Entry #${entry['id']}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.isArabic
                  ? 'اضغط على زر التحميل أعلاه لحفظ القيد كـ PDF'
                  : 'Click the download button above to save the entry as PDF',
              style: TextStyle(
                fontSize: 16,
                color: Colors.grey.shade600,
              ),
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

    double totalDebitCash = 0;
    double totalCreditCash = 0;
    double totalDebitGold = 0;
    double totalCreditGold = 0;

    for (var line in lines) {
      totalDebitCash += (line['debit_cash'] ?? 0.0);
      totalCreditCash += (line['credit_cash'] ?? 0.0);
      totalDebitGold += (line['debit_gold'] ?? 0.0);
      totalCreditGold += (line['credit_gold'] ?? 0.0);
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.receipt_long,
                  color: Color(0xFFD4AF37),
                ),
                const SizedBox(width: 12),
                Text(
                  widget.isArabic ? 'ملخص القيد اليومي' : 'Journal Entry Summary',
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
              '#${entry['id']}',
            ),
            _buildInfoRow(
              widget.isArabic ? 'التاريخ' : 'Date',
              entry['date'] ?? '',
            ),
            _buildInfoRow(
              widget.isArabic ? 'نوع القيد' : 'Entry Type',
              entry['entry_type'] ?? '',
            ),
            _buildInfoRow(
              widget.isArabic ? 'عدد الحسابات' : 'Number of Lines',
              '${lines.length}',
            ),
            const Divider(height: 16),
            Text(
              widget.isArabic ? 'الإجماليات:' : 'Totals:',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
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
            if (entry['description'] != null && entry['description'].toString().isNotEmpty)
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
            style: TextStyle(
              color: Colors.grey.shade700,
              fontSize: 14,
            ),
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
    switch (_paperSize) {
      case 'A5':
        return PdfPageFormat.a5;
      case 'Letter':
        return PdfPageFormat.letter;
      case 'Thermal':
        return const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity);
      default:
        return PdfPageFormat.a4;
    }
  }

  Future<Uint8List> _generatePdf(PdfPageFormat format) async {
    final pdf = pw.Document();
    final entry = widget.journalEntry;
    final lines = (entry['lines'] as List<dynamic>?) ?? [];
    
    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');

    // Calculate totals
    double totalDebitCash = 0;
    double totalCreditCash = 0;
    double totalDebitGold = 0;
    double totalCreditGold = 0;

    for (var line in lines) {
      totalDebitCash += (line['debit_cash'] ?? 0.0);
      totalCreditCash += (line['credit_cash'] ?? 0.0);
      totalDebitGold += (line['debit_gold'] ?? 0.0);
      totalCreditGold += (line['credit_gold'] ?? 0.0);
    }

    pdf.addPage(
      pw.Page(
        pageFormat: format,
        textDirection: widget.isArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        theme: pw.ThemeData.withFont(
          base: await PdfGoogleFonts.cairoRegular(),
          bold: await PdfGoogleFonts.cairoBold(),
        ),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Header
              pw.Container(
                padding: const pw.EdgeInsets.all(20),
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
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                            color: PdfColor.fromHex('#D4AF37'),
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          '#${entry['id']}',
                          style: const pw.TextStyle(fontSize: 14),
                        ),
                      ],
                    ),
                    if (_showLogo)
                      pw.Container(
                        width: 60,
                        height: 60,
                        decoration: pw.BoxDecoration(
                          color: PdfColor.fromHex('#D4AF37'),
                          shape: pw.BoxShape.circle,
                        ),
                        child: pw.Center(
                          child: pw.Text(
                            widget.isArabic ? 'يسر' : 'YASAR',
                            style: pw.TextStyle(
                              color: PdfColors.white,
                              fontWeight: pw.FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              pw.SizedBox(height: 30),

              // Entry Info
              _buildPdfSection(
                widget.isArabic ? 'معلومات القيد' : 'Entry Information',
                [
                  _buildPdfRow(
                    widget.isArabic ? 'التاريخ' : 'Date',
                    entry['date'] ?? '',
                  ),
                  _buildPdfRow(
                    widget.isArabic ? 'نوع القيد' : 'Entry Type',
                    entry['entry_type'] ?? '',
                  ),
                  if (entry['description'] != null && entry['description'].toString().isNotEmpty)
                    pw.Container(
                      margin: const pw.EdgeInsets.only(top: 8),
                      padding: const pw.EdgeInsets.all(8),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#F5F5F5'),
                        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
                      ),
                      child: pw.Text(
                        '${widget.isArabic ? 'البيان' : 'Description'}: ${entry['description']}',
                        style: const pw.TextStyle(fontSize: 11),
                      ),
                    ),
                ],
              ),

              pw.SizedBox(height: 20),

              // Journal Lines Table
              pw.Container(
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                ),
                child: pw.Column(
                  children: [
                    // Table Header
                    pw.Container(
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#D4AF37'),
                        borderRadius: const pw.BorderRadius.only(
                          topLeft: pw.Radius.circular(8),
                          topRight: pw.Radius.circular(8),
                        ),
                      ),
                      child: pw.Row(
                        children: [
                          pw.Expanded(
                            flex: 3,
                            child: pw.Text(
                              widget.isArabic ? 'الحساب' : 'Account',
                              style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11,
                              ),
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              widget.isArabic ? 'مدين (نقد)' : 'Debit (Cash)',
                              style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              widget.isArabic ? 'دائن (نقد)' : 'Credit (Cash)',
                              style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              widget.isArabic ? 'مدين (ذهب)' : 'Debit (Gold)',
                              style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              widget.isArabic ? 'دائن (ذهب)' : 'Credit (Gold)',
                              style: pw.TextStyle(
                                color: PdfColors.white,
                                fontWeight: pw.FontWeight.bold,
                                fontSize: 11,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Table Rows
                    ...lines.asMap().entries.map((e) {
                      final index = e.key;
                      final line = e.value;
                      final isEven = index % 2 == 0;
                      
                      return pw.Container(
                        padding: const pw.EdgeInsets.all(10),
                        decoration: pw.BoxDecoration(
                          color: isEven ? PdfColors.white : PdfColor.fromHex('#F9F9F9'),
                        ),
                        child: pw.Row(
                          children: [
                            pw.Expanded(
                              flex: 3,
                              child: pw.Text(
                                line['account_name'] ?? '',
                                style: const pw.TextStyle(fontSize: 10),
                              ),
                            ),
                            pw.Expanded(
                              flex: 2,
                              child: pw.Text(
                                line['debit_cash'] != null && line['debit_cash'] != 0
                                    ? currencyFormat.format(line['debit_cash'])
                                    : '-',
                                style: const pw.TextStyle(fontSize: 10),
                                textAlign: pw.TextAlign.center,
                              ),
                            ),
                            pw.Expanded(
                              flex: 2,
                              child: pw.Text(
                                line['credit_cash'] != null && line['credit_cash'] != 0
                                    ? currencyFormat.format(line['credit_cash'])
                                    : '-',
                                style: const pw.TextStyle(fontSize: 10),
                                textAlign: pw.TextAlign.center,
                              ),
                            ),
                            pw.Expanded(
                              flex: 2,
                              child: pw.Text(
                                line['debit_gold'] != null && line['debit_gold'] != 0
                                    ? goldFormat.format(line['debit_gold'])
                                    : '-',
                                style: const pw.TextStyle(fontSize: 10),
                                textAlign: pw.TextAlign.center,
                              ),
                            ),
                            pw.Expanded(
                              flex: 2,
                              child: pw.Text(
                                line['credit_gold'] != null && line['credit_gold'] != 0
                                    ? goldFormat.format(line['credit_gold'])
                                    : '-',
                                style: const pw.TextStyle(fontSize: 10),
                                textAlign: pw.TextAlign.center,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                    // Totals Row
                    pw.Container(
                      padding: const pw.EdgeInsets.all(10),
                      decoration: pw.BoxDecoration(
                        color: PdfColor.fromHex('#FFF9E6'),
                        border: pw.Border(
                          top: pw.BorderSide(color: PdfColors.grey400, width: 2),
                        ),
                      ),
                      child: pw.Row(
                        children: [
                          pw.Expanded(
                            flex: 3,
                            child: pw.Text(
                              widget.isArabic ? 'الإجمالي' : 'Total',
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                              ),
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              currencyFormat.format(totalDebitCash),
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              currencyFormat.format(totalCreditCash),
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              goldFormat.format(totalDebitGold),
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                          pw.Expanded(
                            flex: 2,
                            child: pw.Text(
                              goldFormat.format(totalCreditGold),
                              style: pw.TextStyle(
                                fontSize: 11,
                                fontWeight: pw.FontWeight.bold,
                              ),
                              textAlign: pw.TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              pw.Spacer(),

              // Footer - Signatures
              pw.Container(
                padding: const pw.EdgeInsets.all(20),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    _buildSignatureBox(
                      widget.isArabic ? 'المحاسب' : 'Accountant',
                    ),
                    _buildSignatureBox(
                      widget.isArabic ? 'المراجع' : 'Reviewer',
                    ),
                    _buildSignatureBox(
                      widget.isArabic ? 'المدير' : 'Manager',
                    ),
                  ],
                ),
              ),

              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text(
                  '${widget.isArabic ? 'تاريخ الطباعة' : 'Printed on'}: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
                  style: pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey600,
                  ),
                ),
              ),
            ],
          );
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
          pw.Text(
            label,
            style: const pw.TextStyle(fontSize: 12),
          ),
          pw.Text(
            value,
            style: const pw.TextStyle(fontSize: 12),
          ),
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
          pw.Text(
            label,
            style: const pw.TextStyle(fontSize: 11),
          ),
        ],
      ),
    );
  }
}
