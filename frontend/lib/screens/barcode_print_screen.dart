import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:barcode_widget/barcode_widget.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:barcode/barcode.dart' as barcode_lib;
import '../utils.dart';

/// شاشة معاينة وطباعة الباركود
///
/// الميزات:
/// - معاينة حية للباركود
/// - دعم أنواع متعددة (Code128, QR Code, EAN13)
/// - طباعة مباشرة أو حفظ PDF
/// - ملصقات جاهزة للطابعات الحرارية
class BarcodePrintScreen extends StatefulWidget {
  final String barcode;
  final String itemName;
  final String itemCode;
  final double? price;
  final String? karat;

  const BarcodePrintScreen({
    super.key,
    required this.barcode,
    required this.itemName,
    required this.itemCode,
    this.price,
    this.karat,
  });

  @override
  State<BarcodePrintScreen> createState() => _BarcodePrintScreenState();
}

class _BarcodePrintScreenState extends State<BarcodePrintScreen> {
  BarcodeType _selectedType = BarcodeType.code128;
  int _labelCount = 1;
  bool _showPrice = true;
  bool _showItemCode = true;
  bool _showKarat = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('طباعة الباركود'),
        backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.1),
        actions: [
          IconButton(
            icon: const Icon(Icons.print),
            tooltip: 'طباعة',
            onPressed: _printBarcode,
          ),
          IconButton(
            icon: const Icon(Icons.picture_as_pdf),
            tooltip: 'حفظ PDF',
            onPressed: _savePDF,
          ),
        ],
      ),
      body: Column(
        children: [
          // معاينة الباركود
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // بطاقة المعاينة
                  Card(
                    elevation: 4,
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          // اسم الصنف
                          Text(
                            widget.itemName,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),

                          // الباركود
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: BarcodeWidget(
                              barcode: _getBarcodeType(),
                              data: widget.barcode,
                              width: 300,
                              height: 100,
                              drawText: true,
                              style: const TextStyle(fontSize: 14),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // معلومات إضافية
                          if (_showItemCode)
                            _buildInfoRow('كود الصنف', widget.itemCode),
                          if (_showKarat && widget.karat != null)
                            _buildInfoRow('العيار', '${widget.karat} قيراط'),
                          if (_showPrice && widget.price != null)
                            _buildInfoRow(
                              'السعر',
                              '${widget.price!.toStringAsFixed(2)} ريال',
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),

                  // خيارات الطباعة
                  _buildPrintOptions(),
                ],
              ),
            ),
          ),

          // أزرار الإجراءات
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 10,
                  offset: const Offset(0, -2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                    label: const Text('إلغاء'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _printBarcode,
                    icon: const Icon(Icons.print),
                    label: Text('طباعة ($_labelCount)'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFD700),
                      foregroundColor: Colors.black,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.grey, fontSize: 14)),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildPrintOptions() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'خيارات الطباعة',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // نوع الباركود
            DropdownButtonFormField<BarcodeType>(
              initialValue: _selectedType,
              decoration: const InputDecoration(
                labelText: 'نوع الباركود',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.qr_code_2),
              ),
              items: const [
                DropdownMenuItem(
                  value: BarcodeType.code128,
                  child: Text('Code 128 (موصى به)'),
                ),
                DropdownMenuItem(
                  value: BarcodeType.qrCode,
                  child: Text('QR Code'),
                ),
                DropdownMenuItem(
                  value: BarcodeType.codeEan13,
                  child: Text('EAN-13'),
                ),
                DropdownMenuItem(
                  value: BarcodeType.code39,
                  child: Text('Code 39'),
                ),
              ],
              onChanged: (value) {
                if (value != null) {
                  setState(() => _selectedType = value);
                }
              },
            ),
            const SizedBox(height: 16),

            // عدد الملصقات
            TextFormField(
              initialValue: _labelCount.toString(),
              decoration: const InputDecoration(
                labelText: 'عدد الملصقات',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.numbers),
                suffixText: 'ملصق',
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [NormalizeNumberFormatter()],
              onChanged: (value) {
                final count = int.tryParse(value);
                if (count != null && count > 0 && count <= 100) {
                  setState(() => _labelCount = count);
                }
              },
            ),
            const SizedBox(height: 16),

            // خيارات العرض
            const Text(
              'المعلومات المعروضة',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('كود الصنف'),
              value: _showItemCode,
              onChanged: (value) =>
                  setState(() => _showItemCode = value ?? true),
              dense: true,
            ),
            if (widget.karat != null)
              CheckboxListTile(
                title: const Text('العيار'),
                value: _showKarat,
                onChanged: (value) =>
                    setState(() => _showKarat = value ?? true),
                dense: true,
              ),
            if (widget.price != null)
              CheckboxListTile(
                title: const Text('السعر'),
                value: _showPrice,
                onChanged: (value) =>
                    setState(() => _showPrice = value ?? true),
                dense: true,
              ),
          ],
        ),
      ),
    );
  }

  barcode_lib.Barcode _getBarcodeType() {
    switch (_selectedType) {
      case BarcodeType.code128:
        return barcode_lib.Barcode.code128();
      case BarcodeType.qrCode:
        return barcode_lib.Barcode.qrCode();
      case BarcodeType.codeEan13:
        return barcode_lib.Barcode.ean13();
      case BarcodeType.code39:
        return barcode_lib.Barcode.code39();
    }
  }

  Future<void> _printBarcode() async {
    try {
      // إنشاء PDF مرة واحدة فقط
      Uint8List? cachedPdf;

      if (kIsWeb) {
        // للويب: استخدام sharePdf لفتح PDF في نافذة جديدة
        final pdf = await _generatePDF();
        await Printing.sharePdf(
          bytes: pdf,
          filename: 'barcode_${widget.itemCode}.pdf',
        );
      } else {
        // للتطبيقات الأصلية: استخدام حوار الطباعة
        await Printing.layoutPdf(
          onLayout: (PdfPageFormat format) async {
            // إنشاء PDF مرة واحدة فقط وإعادة استخدامه
            cachedPdf ??= await _generatePDF();
            return cachedPdf!;
          },
          name: 'barcode_${widget.itemCode}',
        );
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            kIsWeb
                ? 'تم فتح ملف الباركود. يمكنك طباعته من المتصفح.'
                : 'تم إرسال الباركود إلى الطابعة.',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في الطباعة: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _savePDF() async {
    try {
      final pdf = await _generatePDF();
      await Printing.sharePdf(
        bytes: pdf,
        filename: 'barcode_${widget.itemCode}.pdf',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ تم حفظ PDF بنجاح'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في حفظ PDF: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<Uint8List> _generatePDF() async {
    final pdf = pw.Document();
    final barcodeType = _getBarcodeType();

    // ملصق واحد 50x30 مم (حجم شائع لطابعات الباركود)
    const labelWidth = 50.0 * PdfPageFormat.mm;
    const labelHeight = 30.0 * PdfPageFormat.mm;

    // حساب عدد الملصقات في الصفحة (4 ملصقات في صف، 8 صفوف)
    const labelsPerRow = 4;
    const rows = 8;
    const labelsPerPage = labelsPerRow * rows;

    // إنشاء الصفحات
    for (var page = 0; page < (_labelCount / labelsPerPage).ceil(); page++) {
      final startIdx = page * labelsPerPage;
      final endIdx = (startIdx + labelsPerPage > _labelCount)
          ? _labelCount
          : startIdx + labelsPerPage;
      final pageLabels = endIdx - startIdx;

      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) {
            return pw.Wrap(
              spacing: 2,
              runSpacing: 2,
              children: List.generate(pageLabels, (index) {
                return pw.Container(
                  width: labelWidth,
                  height: labelHeight,
                  decoration: pw.BoxDecoration(
                    border: pw.Border.all(color: PdfColors.grey300),
                  ),
                  child: pw.Padding(
                    padding: const pw.EdgeInsets.all(4),
                    child: pw.Column(
                      mainAxisAlignment: pw.MainAxisAlignment.center,
                      children: [
                        // اسم الصنف
                        pw.Text(
                          widget.itemName,
                          style: pw.TextStyle(
                            fontSize: 8,
                            fontWeight: pw.FontWeight.bold,
                          ),
                          textAlign: pw.TextAlign.center,
                          maxLines: 1,
                          overflow: pw.TextOverflow.clip,
                        ),
                        pw.SizedBox(height: 2),

                        // الباركود
                        pw.BarcodeWidget(
                          barcode: barcodeType,
                          data: widget.barcode,
                          width: labelWidth - 8,
                          height: 15 * PdfPageFormat.mm,
                          drawText: true,
                          textStyle: const pw.TextStyle(fontSize: 6),
                        ),

                        // معلومات إضافية
                        pw.Row(
                          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                          children: [
                            if (_showItemCode)
                              pw.Text(
                                widget.itemCode,
                                style: const pw.TextStyle(fontSize: 6),
                              ),
                            if (_showKarat && widget.karat != null)
                              pw.Text(
                                '${widget.karat}K',
                                style: const pw.TextStyle(fontSize: 6),
                              ),
                            if (_showPrice && widget.price != null)
                              pw.Text(
                                '${widget.price!.toStringAsFixed(0)} ر.س',
                                style: pw.TextStyle(
                                  fontSize: 6,
                                  fontWeight: pw.FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              }),
            );
          },
        ),
      );
    }

    return pdf.save();
  }
}

enum BarcodeType { code128, qrCode, codeEan13, code39 }
