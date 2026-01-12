import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:intl/intl.dart';

/// شاشة معاينة وطباعة السندات (قبض/صرف)
class VoucherPrintScreen extends StatefulWidget {
  final Map<String, dynamic> voucher;
  final bool isArabic;
  final Map<String, dynamic>? printSettings;

  const VoucherPrintScreen({
    super.key,
    required this.voucher,
    this.isArabic = true,
    this.printSettings,
  });

  @override
  State<VoucherPrintScreen> createState() => _VoucherPrintScreenState();
}

class _VoucherPrintScreenState extends State<VoucherPrintScreen> {
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
    final isReceipt = widget.voucher['voucher_type'] == 'receipt';

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isArabic
              ? (isReceipt ? 'طباعة سند قبض' : 'طباعة سند صرف')
              : (isReceipt ? 'Print Receipt Voucher' : 'Print Payment Voucher'),
        ),
        backgroundColor: isReceipt ? Colors.green : Colors.orange,
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
          ? _buildWebPreview(isReceipt)
          : PdfPreview(
              build: (format) => _generatePdf(format),
              canChangePageFormat: true,
              allowPrinting: true,
              allowSharing: true,
              initialPageFormat: _getPdfPageFormat(),
              pdfFileName:
                  'voucher_${widget.voucher['id']}_${DateFormat('yyyyMMdd').format(DateTime.now())}.pdf',
            ),
    );
  }

  Widget _buildWebPreview(bool isReceipt) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              isReceipt ? Icons.arrow_downward : Icons.arrow_upward,
              size: 80,
              color: isReceipt ? Colors.green : Colors.orange,
            ),
            const SizedBox(height: 24),
            Text(
              widget.isArabic
                  ? '${isReceipt ? 'سند قبض' : 'سند صرف'} رقم #${widget.voucher['id']}'
                  : '${isReceipt ? 'Receipt' : 'Payment'} Voucher #${widget.voucher['id']}',
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              widget.isArabic
                  ? 'اضغط على زر التحميل أعلاه لحفظ السند كـ PDF'
                  : 'Click the download button above to save the voucher as PDF',
              style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: _downloadPdf,
              icon: const Icon(Icons.download),
              label: Text(
                widget.isArabic ? 'تحميل السند PDF' : 'Download Voucher PDF',
                style: const TextStyle(fontSize: 18),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isReceipt ? Colors.green : Colors.orange,
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
            _buildVoucherSummary(isReceipt),
          ],
        ),
      ),
    );
  }

  Widget _buildVoucherSummary(bool isReceipt) {
    final voucher = widget.voucher;
    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  isReceipt ? Icons.arrow_downward : Icons.arrow_upward,
                  color: isReceipt ? Colors.green : Colors.orange,
                ),
                const SizedBox(width: 12),
                Text(
                  widget.isArabic ? 'ملخص السند' : 'Voucher Summary',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),
            _buildInfoRow(
              widget.isArabic ? 'رقم السند' : 'Voucher No.',
              '#${voucher['id']}',
            ),
            _buildInfoRow(
              widget.isArabic ? 'التاريخ' : 'Date',
              voucher['date'] ?? '',
            ),
            _buildInfoRow(
              widget.isArabic ? 'الحساب' : 'Account',
              voucher['account_name'] ?? voucher['description'] ?? '',
            ),
            const Divider(height: 16),
            if (voucher['amount_cash'] != null && voucher['amount_cash'] != 0)
              _buildInfoRow(
                widget.isArabic ? 'المبلغ نقداً' : 'Cash Amount',
                '${currencyFormat.format(voucher['amount_cash'])} ${widget.isArabic ? 'ريال' : 'SAR'}',
                isAmount: true,
              ),
            if (voucher['amount_gold'] != null && voucher['amount_gold'] != 0)
              _buildInfoRow(
                widget.isArabic ? 'وزن الذهب' : 'Gold Weight',
                '${goldFormat.format(voucher['amount_gold'])} ${widget.isArabic ? 'جرام' : 'g'}',
                isAmount: true,
              ),
            if (voucher['notes'] != null &&
                voucher['notes'].toString().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.isArabic ? 'ملاحظات:' : 'Notes:',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(voucher['notes'].toString()),
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
        name: 'voucher_${widget.voucher['id']}.pdf',
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? '✓ تم تحميل السند بنجاح'
                  : '✓ Voucher downloaded successfully',
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
    final voucher = widget.voucher;
    final isReceipt = voucher['voucher_type'] == 'receipt';

    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');

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
              pw.Container(
                padding: const pw.EdgeInsets.all(20),
                decoration: pw.BoxDecoration(
                  color: isReceipt
                      ? PdfColor.fromHex('#E8F5E9')
                      : PdfColor.fromHex('#FFF3E0'),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(8),
                  ),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    pw.Column(
                      crossAxisAlignment: pw.CrossAxisAlignment.start,
                      children: [
                        pw.Text(
                          widget.isArabic
                              ? (isReceipt ? 'سند قبض' : 'سند صرف')
                              : (isReceipt
                                    ? 'Receipt Voucher'
                                    : 'Payment Voucher'),
                          style: pw.TextStyle(
                            fontSize: 24,
                            fontWeight: pw.FontWeight.bold,
                            color: isReceipt
                                ? PdfColor.fromHex('#2E7D32')
                                : PdfColor.fromHex('#E65100'),
                          ),
                        ),
                        pw.SizedBox(height: 4),
                        pw.Text(
                          '#${voucher['id']}',
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
              ),
              pw.SizedBox(height: 30),

              // Voucher Details
              _buildPdfSection(
                widget.isArabic ? 'تفاصيل السند' : 'Voucher Details',
                [
                  _buildPdfRow(
                    widget.isArabic ? 'التاريخ' : 'Date',
                    voucher['date'] ?? '',
                  ),
                  _buildPdfRow(
                    widget.isArabic ? 'الحساب' : 'Account',
                    voucher['account_name'] ?? voucher['description'] ?? '',
                  ),
                  if (voucher['reference'] != null)
                    _buildPdfRow(
                      widget.isArabic ? 'المرجع' : 'Reference',
                      voucher['reference'].toString(),
                    ),
                ],
              ),

              pw.SizedBox(height: 20),

              // Amounts
              _buildPdfSection(widget.isArabic ? 'المبالغ' : 'Amounts', [
                if (voucher['amount_cash'] != null &&
                    voucher['amount_cash'] != 0)
                  _buildPdfRow(
                    widget.isArabic ? 'المبلغ نقداً' : 'Cash Amount',
                    '${currencyFormat.format(voucher['amount_cash'])} ${widget.isArabic ? 'ريال' : 'SAR'}',
                    isBold: true,
                  ),
                if (voucher['amount_gold'] != null &&
                    voucher['amount_gold'] != 0)
                  _buildPdfRow(
                    widget.isArabic ? 'وزن الذهب' : 'Gold Weight',
                    '${goldFormat.format(voucher['amount_gold'])} ${widget.isArabic ? 'جرام' : 'g'}',
                    isBold: true,
                  ),
              ]),

              if (voucher['notes'] != null &&
                  voucher['notes'].toString().isNotEmpty) ...[
                pw.SizedBox(height: 20),
                _buildPdfSection(widget.isArabic ? 'ملاحظات' : 'Notes', [
                  pw.Text(
                    voucher['notes'].toString(),
                    style: const pw.TextStyle(fontSize: 12),
                  ),
                ]),
              ],

              pw.Spacer(),

              // Footer - Signatures
              pw.Container(
                padding: const pw.EdgeInsets.all(20),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey300),
                  borderRadius: const pw.BorderRadius.all(
                    pw.Radius.circular(8),
                  ),
                ),
                child: pw.Row(
                  mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                  children: [
                    _buildSignatureBox(
                      widget.isArabic ? 'المستلم' : 'Received By',
                    ),
                    _buildSignatureBox(
                      widget.isArabic ? 'المحاسب' : 'Accountant',
                    ),
                    _buildSignatureBox(widget.isArabic ? 'المدير' : 'Manager'),
                  ],
                ),
              ),

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

  pw.Widget _buildPdfRow(String label, String value, {bool isBold = false}) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4),
      child: pw.Row(
        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
        children: [
          pw.Text(label, style: const pw.TextStyle(fontSize: 12)),
          pw.Text(
            value,
            style: pw.TextStyle(
              fontSize: 12,
              fontWeight: isBold ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
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
          pw.Text(label, style: const pw.TextStyle(fontSize: 11)),
        ],
      ),
    );
  }
}
