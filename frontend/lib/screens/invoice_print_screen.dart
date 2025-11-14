import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';

/// شاشة معاينة وطباعة الفواتير
///
/// تدعم:
/// - فواتير البيع والشراء
/// - فواتير المرتجع والخردة
/// - طباعة احترافية مع شعار الشركة
/// - تصدير PDF
class InvoicePrintScreen extends StatefulWidget {
  final Map<String, dynamic> invoice;
  final bool isArabic;
  final Map<String, dynamic>? printSettings;

  const InvoicePrintScreen({
    super.key,
    required this.invoice,
    this.isArabic = true,
    this.printSettings,
  });

  @override
  State<InvoicePrintScreen> createState() => _InvoicePrintScreenState();
}

class _InvoicePrintScreenState extends State<InvoicePrintScreen> {
  bool _isGenerating = false;

  // إعدادات الطباعة الافتراضية
  late bool _showLogo;
  late bool _showAddress;
  late bool _showPrices;
  late bool _showTaxInfo;
  late bool _showNotes;
  late String _paperSize;
  late bool _printInColor;

  @override
  void initState() {
    super.initState();
    _loadPrintSettings();
  }

  void _loadPrintSettings() {
    final settings = widget.printSettings ?? {};
    _showLogo = settings['showLogo'] ?? true;
    _showAddress = settings['showAddress'] ?? true;
    _showPrices = settings['showPrices'] ?? true;
    _showTaxInfo = settings['showTaxInfo'] ?? true;
    _showNotes = settings['showNotes'] ?? true;
    _paperSize = settings['paperSize'] ?? 'A4';
    _printInColor = settings['printInColor'] ?? true;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'طباعة الفاتورة' : 'Print Invoice'),
        backgroundColor: const Color(0xFFD4AF37),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showPrintSettings,
            tooltip: widget.isArabic ? 'إعدادات الطباعة' : 'Print Settings',
          ),
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
                  canChangeOrientation: true,
                  canDebug: false,
                  allowPrinting: true,
                  allowSharing: true,
                  initialPageFormat: _getPdfPageFormat(),
                  pdfFileName:
                      'invoice_${widget.invoice['invoice_type_id']}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
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
            Icon(
              Icons.picture_as_pdf,
              size: 80,
              color: const Color(0xFFD4AF37),
            ),
            const SizedBox(height: 24),
            Text(
              widget.isArabic
                  ? 'فاتورة رقم #${widget.invoice['invoice_type_id']}'
                  : 'Invoice #${widget.invoice['invoice_type_id']}',
              style: const TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              widget.isArabic
                  ? 'اضغط على زر التحميل أعلاه لحفظ الفاتورة كـ PDF'
                  : 'Click the download button above to save the invoice as PDF',
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
                widget.isArabic ? 'تحميل الفاتورة PDF' : 'Download Invoice PDF',
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
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () async {
                try {
                  setState(() => _isGenerating = true);
                  final pdf = await _generatePdf(_getPdfPageFormat());
                  await Printing.layoutPdf(
                    onLayout: (_) => pdf,
                  );
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('$e'),
                        backgroundColor: Colors.orange,
                      ),
                    );
                  }
                } finally {
                  if (mounted) {
                    setState(() => _isGenerating = false);
                  }
                }
              },
              icon: const Icon(Icons.print),
              label: Text(
                widget.isArabic ? 'طباعة (تجريبي)' : 'Print (Beta)',
              ),
              style: OutlinedButton.styleFrom(
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
            _buildInvoiceSummary(),
          ],
        ),
      ),
    );
  }

  Widget _buildInvoiceSummary() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.isArabic ? 'ملخص الفاتورة' : 'Invoice Summary',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Divider(height: 24),
            _buildSummaryRow(
              widget.isArabic ? 'نوع الفاتورة:' : 'Type:',
              widget.invoice['invoice_type'] ?? '',
            ),
            _buildSummaryRow(
              widget.isArabic ? 'التاريخ:' : 'Date:',
              widget.invoice['date'] ?? '',
            ),
            if (widget.invoice['customer_name'] != null)
              _buildSummaryRow(
                widget.isArabic ? 'العميل:' : 'Customer:',
                widget.invoice['customer_name'] ?? '',
              ),
            if (_showPrices) ...[
              const Divider(height: 24),
              _buildSummaryRow(
                widget.isArabic ? 'الإجمالي:' : 'Total:',
                '${widget.invoice['total']} ${widget.isArabic ? 'ريال' : 'SAR'}',
                isBold: true,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade700,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
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
      final fileName = 'invoice_${widget.invoice['invoice_type_id']}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf';
      
      // Save and share the PDF
      await Printing.sharePdf(
        bytes: pdf,
        filename: fileName,
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? '✓ تم تحميل الفاتورة بنجاح'
                  : '✓ Invoice downloaded successfully',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'خطأ في تحميل الفاتورة: $e'
                  : 'Error downloading invoice: $e',
            ),
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
    final doc = pw.Document();

    // تحميل الخط العربي
    final arabicFont = await PdfGoogleFonts.cairoRegular();
    final arabicFontBold = await PdfGoogleFonts.cairoBold();

    doc.addPage(
      pw.Page(
        pageFormat: format,
        textDirection: widget.isArabic ? pw.TextDirection.rtl : pw.TextDirection.ltr,
        theme: pw.ThemeData.withFont(
          base: arabicFont,
          bold: arabicFontBold,
        ),
        build: (context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              // رأس الفاتورة
              _buildHeader(context),
              pw.SizedBox(height: 20),

              // معلومات الفاتورة الأساسية
              _buildInvoiceInfo(context),
              pw.SizedBox(height: 20),

              // جدول الأصناف
              _buildItemsTable(context),
              pw.SizedBox(height: 20),

              // الإجماليات
              _buildTotals(context),
              pw.SizedBox(height: 20),

              // الملاحظات
              if (_showNotes && widget.invoice['notes'] != null)
                _buildNotes(context),

              pw.Spacer(),

              // ذيل الفاتورة
              _buildFooter(context),
            ],
          );
        },
      ),
    );

    return doc.save();
  }

  pw.Widget _buildHeader(pw.Context context) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400, width: 2),
        ),
      ),
      padding: const pw.EdgeInsets.only(bottom: 10),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          // شعار ومعلومات الشركة
          pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              if (_showLogo)
                pw.Text(
                  widget.isArabic ? 'محل ياسر للذهب والمجوهرات' : 'Yasar Gold & Jewelry',
                  style: pw.TextStyle(
                    fontSize: 20,
                    fontWeight: pw.FontWeight.bold,
                    color: _printInColor ? const PdfColor.fromInt(0xFFD4AF37) : PdfColors.black,
                  ),
                ),
              if (_showAddress) ...[
                pw.SizedBox(height: 5),
                pw.Text(
                  widget.isArabic ? 'العنوان: المملكة العربية السعودية' : 'Address: Saudi Arabia',
                  style: const pw.TextStyle(fontSize: 10),
                ),
                pw.Text(
                  widget.isArabic ? 'هاتف: +966-XXX-XXXX' : 'Phone: +966-XXX-XXXX',
                  style: const pw.TextStyle(fontSize: 10),
                ),
                if (_showTaxInfo)
                  pw.Text(
                    widget.isArabic ? 'الرقم الضريبي: 123456789' : 'VAT No: 123456789',
                    style: const pw.TextStyle(fontSize: 10),
                  ),
              ],
            ],
          ),

          // نوع الفاتورة
          pw.Container(
            padding: const pw.EdgeInsets.all(10),
            decoration: pw.BoxDecoration(
              color: _printInColor ? const PdfColor.fromInt(0xFFD4AF37) : PdfColors.grey300,
              borderRadius: pw.BorderRadius.circular(8),
            ),
            child: pw.Column(
              children: [
                pw.Text(
                  widget.isArabic ? 'فاتورة' : 'Invoice',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: _printInColor ? PdfColors.white : PdfColors.black,
                  ),
                ),
                pw.Text(
                  '${widget.invoice['invoice_type'] ?? ''}',
                  style: pw.TextStyle(
                    fontSize: 14,
                    color: _printInColor ? PdfColors.white : PdfColors.black,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildInvoiceInfo(pw.Context context) {
    final dateFormat = DateFormat('yyyy-MM-dd');
    final invoiceDate = DateTime.parse(widget.invoice['date'] ?? DateTime.now().toIso8601String());

    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            _buildInfoRow(
              widget.isArabic ? 'رقم الفاتورة:' : 'Invoice No:',
              '#${widget.invoice['invoice_type_id'] ?? ''}',
            ),
            _buildInfoRow(
              widget.isArabic ? 'التاريخ:' : 'Date:',
              dateFormat.format(invoiceDate),
            ),
            if (widget.invoice['customer_name'] != null)
              _buildInfoRow(
                widget.isArabic ? 'العميل:' : 'Customer:',
                widget.invoice['customer_name'] ?? '',
              ),
            if (widget.invoice['supplier_name'] != null)
              _buildInfoRow(
                widget.isArabic ? 'المورد:' : 'Supplier:',
                widget.invoice['supplier_name'] ?? '',
              ),
          ],
        ),
        if (widget.invoice['is_posted'] == true)
          pw.Container(
            padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: pw.BoxDecoration(
              color: _printInColor ? PdfColors.green : PdfColors.grey300,
              borderRadius: pw.BorderRadius.circular(12),
            ),
            child: pw.Text(
              widget.isArabic ? 'مرحّل' : 'Posted',
              style: pw.TextStyle(
                color: _printInColor ? PdfColors.white : PdfColors.black,
                fontWeight: pw.FontWeight.bold,
              ),
            ),
          ),
      ],
    );
  }

  pw.Widget _buildInfoRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.only(bottom: 4),
      child: pw.Row(
        children: [
          pw.Text(
            label,
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
          ),
          pw.SizedBox(width: 8),
          pw.Text(value, style: const pw.TextStyle(fontSize: 11)),
        ],
      ),
    );
  }

  pw.Widget _buildItemsTable(pw.Context context) {
    final items = widget.invoice['items'] as List? ?? [];

    return pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey400),
      columnWidths: {
        0: const pw.FlexColumnWidth(1),
        1: const pw.FlexColumnWidth(3),
        2: const pw.FlexColumnWidth(1.5),
        3: const pw.FlexColumnWidth(1.5),
        if (_showPrices) 4: const pw.FlexColumnWidth(2),
      },
      children: [
        // رأس الجدول
        pw.TableRow(
          decoration: pw.BoxDecoration(
            color: _printInColor
                ? PdfColors.yellow100
                : PdfColors.grey300,
          ),
          children: [
            _buildTableCell(widget.isArabic ? '#' : 'No', isHeader: true),
            _buildTableCell(widget.isArabic ? 'اسم الصنف' : 'Item Name', isHeader: true),
            _buildTableCell(widget.isArabic ? 'العيار' : 'Karat', isHeader: true),
            _buildTableCell(widget.isArabic ? 'الوزن (جم)' : 'Weight (g)', isHeader: true),
            if (_showPrices)
              _buildTableCell(widget.isArabic ? 'السعر' : 'Price', isHeader: true),
          ],
        ),

        // بيانات الأصناف
        ...items.asMap().entries.map((entry) {
          final index = entry.key;
          final item = entry.value;
          return pw.TableRow(
            children: [
              _buildTableCell('${index + 1}'),
              _buildTableCell(item['name'] ?? ''),
              _buildTableCell('${item['karat'] ?? ''}'),
              _buildTableCell('${item['weight'] ?? 0}'),
              if (_showPrices)
                _buildTableCell('${(item['price'] ?? 0).toStringAsFixed(2)}'),
            ],
          );
        }).toList(),
      ],
    );
  }

  pw.Widget _buildTableCell(String text, {bool isHeader = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.all(6),
      child: pw.Text(
        text,
        style: pw.TextStyle(
          fontSize: isHeader ? 11 : 10,
          fontWeight: isHeader ? pw.FontWeight.bold : pw.FontWeight.normal,
        ),
        textAlign: pw.TextAlign.center,
      ),
    );
  }

  pw.Widget _buildTotals(pw.Context context) {
    if (!_showPrices) return pw.SizedBox();

    final total = widget.invoice['total'] ?? 0;
    final totalTax = widget.invoice['total_tax'] ?? 0;
    final subtotal = total - totalTax;

    return pw.Container(
      alignment: pw.Alignment.centerLeft,
      child: pw.Container(
        width: 200,
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
          borderRadius: pw.BorderRadius.circular(8),
        ),
        padding: const pw.EdgeInsets.all(10),
        child: pw.Column(
          children: [
            _buildTotalRow(
              widget.isArabic ? 'المجموع الفرعي:' : 'Subtotal:',
              subtotal.toStringAsFixed(2),
            ),
            if (_showTaxInfo && totalTax > 0) ...[
              pw.SizedBox(height: 5),
              _buildTotalRow(
                widget.isArabic ? 'ضريبة القيمة المضافة:' : 'VAT:',
                totalTax.toStringAsFixed(2),
              ),
            ],
            pw.Divider(color: PdfColors.grey400),
            _buildTotalRow(
              widget.isArabic ? 'الإجمالي:' : 'Total:',
              total.toStringAsFixed(2),
              isBold: true,
            ),
          ],
        ),
      ),
    );
  }

  pw.Widget _buildTotalRow(String label, String value, {bool isBold = false}) {
    return pw.Row(
      mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
      children: [
        pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
        pw.Text(
          '$value ${widget.isArabic ? 'ريال' : 'SAR'}',
          style: pw.TextStyle(
            fontSize: 10,
            fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
          ),
        ),
      ],
    );
  }

  pw.Widget _buildNotes(pw.Context context) {
    return pw.Container(
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey400),
        borderRadius: pw.BorderRadius.circular(8),
      ),
      padding: const pw.EdgeInsets.all(10),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            widget.isArabic ? 'ملاحظات:' : 'Notes:',
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11),
          ),
          pw.SizedBox(height: 5),
          pw.Text(
            widget.invoice['notes'] ?? '',
            style: const pw.TextStyle(fontSize: 10),
          ),
        ],
      ),
    );
  }

  pw.Widget _buildFooter(pw.Context context) {
    return pw.Container(
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          top: pw.BorderSide(color: PdfColors.grey400),
        ),
      ),
      padding: const pw.EdgeInsets.only(top: 10),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(
            widget.isArabic
                ? 'شكراً لتعاملكم معنا'
                : 'Thank you for your business',
            style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
          ),
          pw.Text(
            '${widget.isArabic ? 'تاريخ الطباعة:' : 'Print Date:'} ${DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now())}',
            style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
          ),
        ],
      ),
    );
  }

  void _showPrintSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'إعدادات الطباعة' : 'Print Settings'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض الشعار' : 'Show Logo'),
                value: _showLogo,
                onChanged: (val) => setState(() => _showLogo = val),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض العنوان' : 'Show Address'),
                value: _showAddress,
                onChanged: (val) => setState(() => _showAddress = val),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض الأسعار' : 'Show Prices'),
                value: _showPrices,
                onChanged: (val) => setState(() => _showPrices = val),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'معلومات الضريبة' : 'Tax Info'),
                value: _showTaxInfo,
                onChanged: (val) => setState(() => _showTaxInfo = val),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'عرض الملاحظات' : 'Show Notes'),
                value: _showNotes,
                onChanged: (val) => setState(() => _showNotes = val),
              ),
              SwitchListTile(
                title: Text(widget.isArabic ? 'طباعة ملونة' : 'Color Print'),
                value: _printInColor,
                onChanged: (val) => setState(() => _printInColor = val),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.isArabic ? 'إغلاق' : 'Close'),
          ),
        ],
      ),
    );
  }
}
