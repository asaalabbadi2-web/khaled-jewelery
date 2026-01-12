import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';

/// شاشة عامة لطباعة التقارير المختلفة
class GenericReportPrintScreen extends StatefulWidget {
  final String reportTitle;
  final String reportType;
  final Map<String, dynamic> reportData;
  final bool isArabic;
  final Map<String, dynamic>? printSettings;

  const GenericReportPrintScreen({
    super.key,
    required this.reportTitle,
    required this.reportType,
    required this.reportData,
    this.isArabic = true,
    this.printSettings,
  });

  @override
  State<GenericReportPrintScreen> createState() =>
      _GenericReportPrintScreenState();
}

class _GenericReportPrintScreenState extends State<GenericReportPrintScreen> {
  bool _isGenerating = false;

  late bool _showLogo;
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
    _paperSize = settings['paperSize'] ?? 'A4';
    _orientation = settings['orientation'] ?? 'portrait';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isArabic
              ? 'طباعة ${widget.reportTitle}'
              : 'Print ${widget.reportTitle}',
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
                  '${widget.reportType}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
            ),
    );
  }

  Widget _buildWebPreview() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.assessment, size: 80, color: Color(0xFFD4AF37)),
            const SizedBox(height: 24),
            Text(
              widget.reportTitle,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              widget.isArabic
                  ? 'اضغط على زر التحميل أعلاه لحفظ التقرير كـ PDF'
                  : 'Click the download button above to save the report as PDF',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _downloadPdf,
              icon: const Icon(Icons.download),
              label: Text(
                widget.isArabic ? 'تحميل التقرير PDF' : 'Download Report PDF',
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
            _buildReportSummary(),
          ],
        ),
      ),
    );
  }

  Widget _buildReportSummary() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.assessment, color: Color(0xFFD4AF37)),
                const SizedBox(width: 12),
                Text(
                  widget.isArabic ? 'ملخص التقرير' : 'Report Summary',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _buildInfoRow(
              widget.isArabic ? 'نوع التقرير' : 'Report Type',
              widget.reportTitle,
            ),
            if (widget.reportData['date_from'] != null)
              _buildInfoRow(
                widget.isArabic ? 'من تاريخ' : 'From Date',
                widget.reportData['date_from'].toString(),
              ),
            if (widget.reportData['date_to'] != null)
              _buildInfoRow(
                widget.isArabic ? 'إلى تاريخ' : 'To Date',
                widget.reportData['date_to'].toString(),
              ),
            if (widget.reportData['total_records'] != null)
              _buildInfoRow(
                widget.isArabic ? 'عدد السجلات' : 'Total Records',
                widget.reportData['total_records'].toString(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
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
              fontWeight: FontWeight.normal,
              fontSize: 14,
              color: Colors.grey.shade800,
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
        name: '${widget.reportType}.pdf',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? '✓ تم تحميل التقرير بنجاح'
                  : '✓ Report downloaded successfully',
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
    PdfPageFormat baseFormat;
    switch (_paperSize) {
      case 'A5':
        baseFormat = PdfPageFormat.a5;
        break;
      case 'Letter':
        baseFormat = PdfPageFormat.letter;
        break;
      case 'Legal':
        baseFormat = PdfPageFormat.legal;
        break;
      default:
        baseFormat = PdfPageFormat.a4;
    }

    if (_orientation == 'landscape') {
      return baseFormat.landscape;
    }
    return baseFormat;
  }

  Future<Uint8List> _generatePdf(PdfPageFormat format) async {
    final pdf = pw.Document();

    // Extract data based on report type
    final items = widget.reportData['items'] as List<dynamic>? ?? [];
    final summary = widget.reportData['summary'] as Map<String, dynamic>? ?? {};

    pdf.addPage(
      pw.Page(
        pageFormat: format,
        textDirection: widget.isArabic
            ? pw.TextDirection.rtl
            : pw.TextDirection.ltr,
        theme: pw.ThemeData.withFont(
          base: await PdfGoogleFonts.cairoRegular(),
          bold: await PdfGoogleFonts.cairoBold(),
        ),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // Header
              _buildPdfHeader(),
              pw.SizedBox(height: 20),

              // Report Info
              _buildPdfReportInfo(),
              pw.SizedBox(height: 20),

              // Report Content
              if (items.isNotEmpty) _buildPdfTable(items),

              pw.Spacer(),

              // Summary
              if (summary.isNotEmpty) _buildPdfSummary(summary),

              pw.SizedBox(height: 10),
              pw.Center(
                child: pw.Text(
                  '${widget.isArabic ? 'تاريخ الطباعة' : 'Printed on'}: ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
                  style: pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
                ),
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  pw.Widget _buildPdfHeader() {
    return pw.Container(
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
                widget.reportTitle,
                style: pw.TextStyle(
                  fontSize: 22,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColor.fromHex('#D4AF37'),
                ),
              ),
              pw.SizedBox(height: 4),
              pw.Text(
                widget.isArabic ? 'مجوهرات خالد' : 'Khaled Jewelry',
                style: const pw.TextStyle(fontSize: 12),
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
                  widget.isArabic ? 'خالد' : 'KHALED',
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
    );
  }

  pw.Widget _buildPdfReportInfo() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(15),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          if (widget.reportData['date_from'] != null)
            _buildPdfInfoRow(
              widget.isArabic ? 'من تاريخ' : 'From',
              widget.reportData['date_from'].toString(),
            ),
          if (widget.reportData['date_to'] != null)
            _buildPdfInfoRow(
              widget.isArabic ? 'إلى تاريخ' : 'To',
              widget.reportData['date_to'].toString(),
            ),
          if (widget.reportData['filter'] != null)
            _buildPdfInfoRow(
              widget.isArabic ? 'فلتر' : 'Filter',
              widget.reportData['filter'].toString(),
            ),
        ],
      ),
    );
  }

  pw.Widget _buildPdfInfoRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
          pw.Text(
            value,
            style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildPdfTable(List<dynamic> items) {
    // Get column headers based on first item
    final firstItem = items.isNotEmpty ? items[0] as Map<String, dynamic> : {};
    final columns = firstItem.keys.toList();

    return pw.Container(
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
              children: columns
                  .map(
                    (col) => pw.Expanded(
                      child: pw.Text(
                        _translateColumnName(col),
                        style: pw.TextStyle(
                          color: PdfColors.white,
                          fontWeight: pw.FontWeight.bold,
                          fontSize: 10,
                        ),
                        textAlign: pw.TextAlign.center,
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
          // Table Rows
          ...items.asMap().entries.map((e) {
            final index = e.key;
            final item = e.value as Map<String, dynamic>;
            final isEven = index % 2 == 0;

            return pw.Container(
              padding: const pw.EdgeInsets.all(8),
              decoration: pw.BoxDecoration(
                color: isEven ? PdfColors.white : PdfColor.fromHex('#F9F9F9'),
              ),
              child: pw.Row(
                children: columns
                    .map(
                      (col) => pw.Expanded(
                        child: pw.Text(
                          _formatValue(item[col]),
                          style: const pw.TextStyle(fontSize: 9),
                          textAlign: pw.TextAlign.center,
                        ),
                      ),
                    )
                    .toList(),
              ),
            );
          }),
        ],
      ),
    );
  }

  pw.Widget _buildPdfSummary(Map<String, dynamic> summary) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(15),
      decoration: pw.BoxDecoration(
        color: PdfColor.fromHex('#FFF9E6'),
        border: pw.Border.all(color: PdfColor.fromHex('#D4AF37'), width: 2),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            widget.isArabic ? 'الملخص' : 'Summary',
            style: pw.TextStyle(
              fontSize: 14,
              fontWeight: pw.FontWeight.bold,
              color: PdfColor.fromHex('#D4AF37'),
            ),
          ),
          pw.SizedBox(height: 10),
          ...summary.entries.map(
            (entry) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 3),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    _translateColumnName(entry.key),
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                  pw.Text(
                    _formatValue(entry.value),
                    style: pw.TextStyle(
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _translateColumnName(String columnName) {
    if (!widget.isArabic) return columnName;

    final translations = {
      'id': 'الرقم',
      'date': 'التاريخ',
      'name': 'الاسم',
      'description': 'الوصف',
      'amount': 'المبلغ',
      'quantity': 'الكمية',
      'weight': 'الوزن',
      'karat': 'العيار',
      'total': 'الإجمالي',
      'debit': 'مدين',
      'credit': 'دائن',
      'balance': 'الرصيد',
      'customer': 'العميل',
      'account': 'الحساب',
      'type': 'النوع',
      'status': 'الحالة',
      'total_cash': 'إجمالي النقد',
      'total_gold': 'إجمالي الذهب',
      'count': 'العدد',
    };

    return translations[columnName] ?? columnName;
  }

  String _formatValue(dynamic value) {
    if (value == null) return '-';
    if (value is num) {
      if (value is double) {
        return NumberFormat('#,##0.00', 'ar').format(value);
      }
      return value.toString();
    }
    return value.toString();
  }
}
