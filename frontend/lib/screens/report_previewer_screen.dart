import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';

/// شاشة عرض وطباعة التقارير العامة
class ReportPreviewerScreen extends StatefulWidget {
  final String reportTitle;
  final String reportType;
  final List<Map<String, dynamic>> rows;
  final Map<String, dynamic>? summary;
  final bool isArabic;
  final Map<String, dynamic>? printSettings;

  const ReportPreviewerScreen({
    super.key,
    required this.reportTitle,
    required this.reportType,
    required this.rows,
    this.summary,
    this.isArabic = true,
    this.printSettings,
  });

  @override
  State<ReportPreviewerScreen> createState() => _ReportPreviewerScreenState();
}

class _ReportPreviewerScreenState extends State<ReportPreviewerScreen> {
  late pw.Document _document;
  bool _isLoading = true;
  late Map<String, dynamic> _settings;

  @override
  void initState() {
    super.initState();
    _settings = widget.printSettings ?? {};
    _document = pw.Document();
    _preparePdf();
  }

  Future<void> _preparePdf() async {
    setState(() => _isLoading = true);

    final items = widget.rows;
    final summary = widget.summary ?? {};
    final isArabic = widget.isArabic;

  final headers = items.isNotEmpty ? items.first.keys.toList() : <String>[];

  _document = pw.Document();

    final tableRows = <pw.TableRow>[
      pw.TableRow(
        decoration: pw.BoxDecoration(
          color: PdfColors.amber100,
        ),
        children: headers
            .map(
              (header) => pw.Padding(
                padding: const pw.EdgeInsets.all(8),
                child: pw.Text(
                  _translateHeader(header, isArabic),
                  style: pw.TextStyle(
                    fontWeight: pw.FontWeight.bold,
                    fontSize: 11,
                    color: PdfColors.amber900,
                  ),
                  textAlign: pw.TextAlign.center,
                ),
              ),
            )
            .toList(),
      ),
      ...items.map(
        (row) => pw.TableRow(
          decoration: pw.BoxDecoration(
            color: PdfColors.grey50,
          ),
          children: headers
              .map(
                (header) => pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 10,
                  ),
                  child: pw.Text(
                    _formatValue(row[header]),
                    style: const pw.TextStyle(fontSize: 10),
                    textAlign: pw.TextAlign.center,
                  ),
                ),
              )
              .toList(),
        ),
      ),
    ];

    _document.addPage(
      pw.MultiPage(
        pageFormat: _resolvePageFormat(),
        textDirection:
            isArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        theme: pw.ThemeData.withFont(
          base: await PdfGoogleFonts.cairoRegular(),
          bold: await PdfGoogleFonts.cairoBold(),
        ),
        build: (context) {
          return [
            _buildHeader(),
            pw.SizedBox(height: 12),
            if (items.isEmpty)
              _buildEmptyState()
            else ...[
              _buildFiltersBlock(),
              pw.SizedBox(height: 12),
              pw.Table(children: tableRows),
              pw.SizedBox(height: 16),
              if (summary.isNotEmpty) _buildSummaryBlock(summary),
            ],
            pw.SizedBox(height: 20),
            _buildFooter(),
          ];
        },
      ),
    );

    setState(() => _isLoading = false);
  }

  pw.Widget _buildHeader() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(16),
      decoration: pw.BoxDecoration(
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12)),
        border: pw.Border.all(color: PdfColors.amber400, width: 1.2),
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
                  color: PdfColors.amber900,
                ),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                widget.isArabic
                    ? 'نظام نقاط بيع يسر للذهب والمجوهرات'
                    : 'Yasar Gold & Jewelry POS',
                style: pw.TextStyle(
                  fontSize: 12,
                  color: PdfColors.grey700,
                ),
              ),
            ],
          ),
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.end,
            children: [
              pw.Text(
                DateFormat('yyyy/MM/dd').format(DateTime.now()),
                style: const pw.TextStyle(fontSize: 12),
              ),
              pw.SizedBox(height: 4),
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: pw.BoxDecoration(
                  color: PdfColors.amber,
                  borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
                ),
                child: pw.Text(
                  widget.isArabic ? 'نسخة للطباعة' : 'Print copy',
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.white,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  pw.Widget _buildFiltersBlock() {
    final filters = <String>[];
    if (widget.printSettings?['dateRange'] != null) {
      filters.add(widget.isArabic
          ? 'الفترة: ${widget.printSettings?['dateRange']}'
          : 'Date range: ${widget.printSettings?['dateRange']}');
    }
    if (widget.printSettings?['accountName'] != null) {
      filters.add(widget.isArabic
          ? 'الحساب: ${widget.printSettings?['accountName']}'
          : 'Account: ${widget.printSettings?['accountName']}');
    }

    if (filters.isEmpty) return pw.SizedBox.shrink();

    return pw.Container(
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.grey200,
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: filters
            .map((filter) => pw.Padding(
                  padding: const pw.EdgeInsets.symmetric(vertical: 2),
                  child: pw.Text(
                    filter,
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                ))
            .toList(),
      ),
    );
  }

  pw.Widget _buildSummaryBlock(Map<String, dynamic> summary) {
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12)),
        border: pw.Border.all(color: PdfColors.amber300, width: 1.2),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            widget.isArabic ? 'الملخص' : 'Summary',
            style: pw.TextStyle(
              fontSize: 14,
              fontWeight: pw.FontWeight.bold,
              color: PdfColors.amber800,
            ),
          ),
          pw.Divider(color: PdfColors.amber200),
          ...summary.entries.map(
            (entry) => pw.Padding(
              padding: const pw.EdgeInsets.symmetric(vertical: 4),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    _translateHeader(entry.key, widget.isArabic),
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

  pw.Widget _buildFooter() {
    return pw.Align(
      alignment: pw.Alignment.center,
      child: pw.Text(
        widget.isArabic
            ? 'تم إنشاء هذا التقرير من مركز الطباعة الذكي'
            : 'Generated by the Smart Printing Center',
        style: pw.TextStyle(
          fontSize: 10,
          color: PdfColors.grey600,
        ),
      ),
    );
  }

  pw.Widget _buildEmptyState() {
    return pw.Container(
      padding: const pw.EdgeInsets.all(20),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(12)),
      ),
      child: pw.Column(
        children: [
          pw.Icon(pw.IconData(0xe16a), size: 48, color: PdfColors.grey400),
          pw.SizedBox(height: 12),
          pw.Text(
            widget.isArabic
                ? 'لا توجد سجلات لعرضها'
                : 'There are no rows to display',
            style: pw.TextStyle(fontSize: 12, color: PdfColors.grey700),
          ),
        ],
      ),
    );
  }

  PdfPageFormat _resolvePageFormat() {
    switch (_settings['paperSize']) {
      case 'A5':
        return PdfPageFormat.a5;
      case 'Thermal':
        return const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity);
      case 'Letter':
        return PdfPageFormat.letter;
      default:
        return PdfPageFormat.a4;
    }
  }

  Future<Uint8List> _export() async {
    return _document.save();
  }

  void _exportPdf() {
    Printing.layoutPdf(
      onLayout: (_) => _export(),
      name: '${widget.reportType}_${DateFormat('yyyyMMdd_HHmm').format(DateTime.now())}.pdf',
    );
  }

  String _translateHeader(String key, bool isArabic) {
    if (!isArabic) return key;
    const map = {
      'date': 'التاريخ',
      'total': 'الإجمالي',
      'customer': 'العميل',
      'account': 'الحساب',
      'quantity': 'الكمية',
      'amount': 'المبلغ',
      'weight': 'الوزن',
      'karat': 'العيار',
      'status': 'الحالة',
      'type': 'النوع',
      'balance': 'الرصيد',
      'reference': 'المرجع',
      'description': 'الوصف',
    };
    return map[key] ?? key;
  }

  String _formatValue(dynamic value) {
    if (value == null) return '-';
    if (value is num) {
      if (value is double) {
        return NumberFormat('#,##0.00').format(value);
      }
      return value.toString();
    }
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: Text(widget.reportTitle),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.reportTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _preparePdf,
            tooltip: widget.isArabic ? 'تحديث' : 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: _exportPdf,
            tooltip: widget.isArabic ? 'تحميل PDF' : 'Download PDF',
          ),
        ],
      ),
      body: PdfPreview(
        build: (_) => _export(),
        maxPageWidth: 700,
        canChangePageFormat: true,
        allowSharing: true,
        canChangeOrientation: true,
        pdfFileName:
            '${widget.reportType}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
        initialPageFormat: _resolvePageFormat(),
        onError: (context, error) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.toString()),
              backgroundColor: Colors.red,
            ),
          );
          return Center(
            child: Text(
              widget.isArabic
                  ? 'تعذر إنشاء ملف PDF'
                  : 'Failed to generate PDF',
            ),
          );
        },
      ),
    );
  }
}
