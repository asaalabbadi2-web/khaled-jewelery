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

  ({
    String typeKey,
    bool isReceipt,
    bool isPayment,
    bool isAdjustment,
    String titleAr,
    String titleEn,
    Color appColor,
    PdfColor headerBg,
    PdfColor accent,
    IconData icon,
  }) _voucherMeta() {
    final typeKey = (widget.voucher['voucher_type']?.toString() ?? '')
        .trim()
        .toLowerCase();

    if (typeKey == 'receipt') {
      return (
        typeKey: typeKey,
        isReceipt: true,
        isPayment: false,
        isAdjustment: false,
        titleAr: 'سند قبض',
        titleEn: 'Receipt Voucher',
        appColor: Colors.green,
        headerBg: PdfColor.fromHex('#E8F5E9'),
        accent: PdfColor.fromHex('#2E7D32'),
        icon: Icons.arrow_downward,
      );
    }

    if (typeKey == 'payment') {
      return (
        typeKey: typeKey,
        isReceipt: false,
        isPayment: true,
        isAdjustment: false,
        titleAr: 'سند صرف',
        titleEn: 'Payment Voucher',
        appColor: Colors.orange,
        headerBg: PdfColor.fromHex('#FFF3E0'),
        accent: PdfColor.fromHex('#E65100'),
        icon: Icons.arrow_upward,
      );
    }

    // Adjustment / settlement voucher.
    return (
      typeKey: typeKey.isEmpty ? 'adjustment' : typeKey,
      isReceipt: false,
      isPayment: false,
      isAdjustment: true,
      titleAr: 'سند تسوية',
      titleEn: 'Adjustment Voucher',
      appColor: Colors.purple,
      headerBg: PdfColor.fromHex('#F3E5F5'),
      accent: PdfColor.fromHex('#6A1B9A'),
      icon: Icons.balance,
    );
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

  String _partyDisplay(Map<String, dynamic> voucher) {
    final partyName = voucher['party_name']?.toString().trim();
    if (partyName != null && partyName.isNotEmpty) return partyName;

    final customer = voucher['customer'];
    if (customer is Map) {
      final name = customer['name']?.toString().trim();
      if (name != null && name.isNotEmpty) return name;
    }

    final supplier = voucher['supplier'];
    if (supplier is Map) {
      final name = supplier['name']?.toString().trim();
      if (name != null && name.isNotEmpty) return name;
    }

    final description = voucher['description']?.toString().trim();
    if (description != null && description.isNotEmpty) return description;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final meta = _voucherMeta();

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.isArabic
              ? 'طباعة ${meta.titleAr}'
              : 'Print ${meta.titleEn}',
        ),
        backgroundColor: meta.appColor,
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
          ? _buildWebPreview(meta)
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

  Widget _buildWebPreview(
    ({
      String typeKey,
      bool isReceipt,
      bool isPayment,
      bool isAdjustment,
      String titleAr,
      String titleEn,
      Color appColor,
      PdfColor headerBg,
      PdfColor accent,
      IconData icon,
    }) meta,
  ) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              meta.icon,
              size: 80,
              color: meta.appColor,
            ),
            const SizedBox(height: 24),
            Text(
              widget.isArabic
                  ? '${meta.titleAr} رقم #${widget.voucher['id']}'
                  : '${meta.titleEn} #${widget.voucher['id']}',
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
                backgroundColor: meta.appColor,
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
            _buildVoucherSummary(meta),
          ],
        ),
      ),
    );
  }

  Widget _buildVoucherSummary(
    ({
      String typeKey,
      bool isReceipt,
      bool isPayment,
      bool isAdjustment,
      String titleAr,
      String titleEn,
      Color appColor,
      PdfColor headerBg,
      PdfColor accent,
      IconData icon,
    }) meta,
  ) {
    final voucher = widget.voucher;
    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');
    final party = _partyDisplay(voucher);

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
                  meta.icon,
                  color: meta.appColor,
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
              (voucher['voucher_number'] != null)
                  ? voucher['voucher_number'].toString()
                  : '#${voucher['id']}',
            ),
            _buildInfoRow(
              widget.isArabic ? 'التاريخ' : 'Date',
              _fmtDate(voucher['date']),
            ),
            if ((voucher['status']?.toString() ?? '').isNotEmpty)
              _buildInfoRow(
                widget.isArabic ? 'الحالة' : 'Status',
                voucher['status'].toString(),
              ),
            if (party.isNotEmpty)
              _buildInfoRow(
                widget.isArabic ? 'الطرف' : 'Party',
                party,
              ),
            _buildInfoRow(
              widget.isArabic ? 'البيان' : 'Description',
              voucher['description']?.toString() ?? '',
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
    final voucher = widget.voucher;
    final meta = _voucherMeta();

    final currencyFormat = NumberFormat('#,##0.00', 'ar');
    final goldFormat = NumberFormat('#,##0.000', 'ar');

    final party = _partyDisplay(voucher);
    final voucherNumber = (voucher['voucher_number'] != null &&
            voucher['voucher_number'].toString().trim().isNotEmpty)
        ? voucher['voucher_number'].toString()
        : '#${voucher['id']}';

    final referenceNumber = voucher['reference_number']?.toString().trim();
    final referenceType = voucher['reference_type']?.toString().trim();
    final status = voucher['status']?.toString().trim();
    final createdBy = voucher['created_by']?.toString().trim();
    final approvedBy = voucher['approved_by']?.toString().trim();
    final rejectionReason = voucher['rejection_reason']?.toString().trim();

    final accountLinesRaw = voucher['account_lines'];
    final accountLines = accountLinesRaw is List
        ? accountLinesRaw.whereType<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[];

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
          final title = widget.isArabic ? meta.titleAr : meta.titleEn;

          pw.Widget header() {
            return pw.Container(
              padding: const pw.EdgeInsets.all(18),
              decoration: pw.BoxDecoration(
                color: meta.headerBg,
                borderRadius: const pw.BorderRadius.all(pw.Radius.circular(8)),
              ),
              child: pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        title,
                        style: pw.TextStyle(
                          fontSize: 22,
                          fontWeight: pw.FontWeight.bold,
                          color: meta.accent,
                        ),
                      ),
                      pw.SizedBox(height: 4),
                      pw.Text(
                        voucherNumber,
                        style: const pw.TextStyle(fontSize: 12),
                      ),
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

          final details = <pw.Widget>[
            _buildPdfRow(
              widget.isArabic ? 'التاريخ' : 'Date',
              _fmtDate(voucher['date']),
            ),
            if (status != null && status.isNotEmpty)
              _buildPdfRow(widget.isArabic ? 'الحالة' : 'Status', status),
            if (party.isNotEmpty)
              _buildPdfRow(widget.isArabic ? 'الطرف' : 'Party', party),
            if (createdBy != null && createdBy.isNotEmpty)
              _buildPdfRow(
                widget.isArabic ? 'أنشئ بواسطة' : 'Created By',
                createdBy,
              ),
            if (approvedBy != null && approvedBy.isNotEmpty)
              _buildPdfRow(
                widget.isArabic ? 'اعتمد بواسطة' : 'Approved By',
                approvedBy,
              ),
            if (referenceType != null && referenceType.isNotEmpty)
              _buildPdfRow(
                widget.isArabic ? 'نوع المرجع' : 'Reference Type',
                referenceType,
              ),
            if (referenceNumber != null && referenceNumber.isNotEmpty)
              _buildPdfRow(
                widget.isArabic ? 'رقم المرجع' : 'Reference No.',
                referenceNumber,
              ),
            if ((voucher['description']?.toString() ?? '').trim().isNotEmpty)
              _buildPdfRow(
                widget.isArabic ? 'البيان' : 'Description',
                voucher['description'].toString(),
              ),
          ];

          final amountWidgets = <pw.Widget>[];
          final cash = (voucher['amount_cash'] is num)
              ? (voucher['amount_cash'] as num).toDouble()
              : double.tryParse(voucher['amount_cash']?.toString() ?? '0') ?? 0;
          final gold = (voucher['amount_gold'] is num)
              ? (voucher['amount_gold'] as num).toDouble()
              : double.tryParse(voucher['amount_gold']?.toString() ?? '0') ?? 0;
          final karat = voucher['gold_karat']?.toString();

          if (cash.abs() > 0.000001) {
            amountWidgets.add(
              _buildPdfRow(
                widget.isArabic ? 'المبلغ نقداً' : 'Cash Amount',
                '${currencyFormat.format(cash)} ${widget.isArabic ? 'ريال' : 'SAR'}',
                isBold: true,
              ),
            );
          }
          if (gold.abs() > 0.000001) {
            final karatSuffix =
                (karat != null && karat.trim().isNotEmpty) ? ' (${karat.trim()})' : '';
            amountWidgets.add(
              _buildPdfRow(
                widget.isArabic ? 'وزن الذهب' : 'Gold Weight',
                '${goldFormat.format(gold)} ${widget.isArabic ? 'جرام' : 'g'}$karatSuffix',
                isBold: true,
              ),
            );
          }

          pw.Widget accountLinesTable() {
            if (accountLines.isEmpty) {
              return pw.Container();
            }

            final headers = <String>[
              widget.isArabic ? 'الحساب' : 'Account',
              widget.isArabic ? 'مدين نقد' : 'Cash Dr',
              widget.isArabic ? 'دائن نقد' : 'Cash Cr',
              widget.isArabic ? 'مدين ذهب' : 'Gold Dr',
              widget.isArabic ? 'دائن ذهب' : 'Gold Cr',
              widget.isArabic ? 'عيار' : 'Karat',
            ];

            List<String> rowFor(Map<String, dynamic> line) {
              final account = (line['account'] is Map)
                  ? (line['account'] as Map)
                  : const {};
              final accountName = account['name']?.toString() ?? '';
              final accountNumber = account['account_number']?.toString() ?? '';
              final accountDisplay =
                  accountNumber.isNotEmpty ? '$accountNumber - $accountName' : accountName;

              final lineType = line['line_type']?.toString().toLowerCase();
              final amountType = line['amount_type']?.toString().toLowerCase();
              final amount = (line['amount'] is num)
                  ? (line['amount'] as num).toDouble()
                  : double.tryParse(line['amount']?.toString() ?? '0') ?? 0;
              final k = line['karat']?.toString();

              String cashDr = '';
              String cashCr = '';
              String goldDr = '';
              String goldCr = '';

              if (amountType == 'cash') {
                if (lineType == 'debit') {
                  cashDr = currencyFormat.format(amount);
                } else {
                  cashCr = currencyFormat.format(amount);
                }
              } else if (amountType == 'gold') {
                if (lineType == 'debit') {
                  goldDr = goldFormat.format(amount);
                } else {
                  goldCr = goldFormat.format(amount);
                }
              }

              return [
                accountDisplay,
                cashDr,
                cashCr,
                goldDr,
                goldCr,
                (amountType == 'gold') ? (k ?? '') : '',
              ];
            }

            final data = accountLines.map(rowFor).toList();

            return pw.TableHelper.fromTextArray(
              headers: headers,
              data: data,
              headerDecoration: pw.BoxDecoration(color: PdfColor.fromHex('#F3F4F6')),
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                fontSize: 9,
              ),
              cellStyle: const pw.TextStyle(fontSize: 9),
              cellPadding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 3),
              border: pw.TableBorder.all(color: PdfColors.grey300),
              columnWidths: {
                0: const pw.FlexColumnWidth(3.2),
                1: const pw.FixedColumnWidth(55),
                2: const pw.FixedColumnWidth(55),
                3: const pw.FixedColumnWidth(55),
                4: const pw.FixedColumnWidth(55),
                5: const pw.FixedColumnWidth(40),
              },
              cellAlignments: {
                0: pw.Alignment.centerRight,
                1: pw.Alignment.center,
                2: pw.Alignment.center,
                3: pw.Alignment.center,
                4: pw.Alignment.center,
                5: pw.Alignment.center,
              },
            );
          }

          final notes = voucher['notes']?.toString().trim();

          final out = <pw.Widget>[
            header(),
            pw.SizedBox(height: 18),
            _buildPdfSection(
              widget.isArabic ? 'تفاصيل السند' : 'Voucher Details',
              details,
            ),
            pw.SizedBox(height: 14),
            if (amountWidgets.isNotEmpty)
              _buildPdfSection(widget.isArabic ? 'المبالغ' : 'Amounts', amountWidgets),
            if (accountLines.isNotEmpty) ...[
              pw.SizedBox(height: 14),
              _buildPdfSection(
                widget.isArabic ? 'سطور الحسابات' : 'Account Lines',
                [accountLinesTable()],
              ),
            ],
            if (notes != null && notes.isNotEmpty) ...[
              pw.SizedBox(height: 14),
              _buildPdfSection(widget.isArabic ? 'ملاحظات' : 'Notes', [
                pw.Text(notes, style: const pw.TextStyle(fontSize: 11)),
              ]),
            ],
            if (rejectionReason != null && rejectionReason.isNotEmpty) ...[
              pw.SizedBox(height: 14),
              _buildPdfSection(widget.isArabic ? 'سبب الرفض' : 'Rejection Reason', [
                pw.Text(rejectionReason, style: const pw.TextStyle(fontSize: 11)),
              ]),
            ],
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
                  _buildSignatureBox(widget.isArabic ? 'المستلم' : 'Received By'),
                  _buildSignatureBox(widget.isArabic ? 'المحاسب' : 'Accountant'),
                  _buildSignatureBox(widget.isArabic ? 'المدير' : 'Manager'),
                ],
              ),
            ),
          ];

          return out;
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
