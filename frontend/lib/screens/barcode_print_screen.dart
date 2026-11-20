import 'dart:typed_data';

import 'package:barcode/barcode.dart' as barcode_lib;
import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../utils.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';

/// A barcode label for an item that is NOT a piece -- a PDF sheet of
/// 50 x 30 mm labels for an ordinary printer.
///
/// A piece («KJ-») never prints here: its label is the station's and
/// «القطع»'s, through the print engine -- its DataMatrix, its RFID tag
/// written and read back (ADR-097). And no price is printed: the price is
/// the day's gold (the owner, 13 Oct; ADR-097 §2). Its colours are the app's.
class BarcodePrintScreen extends StatefulWidget {
  final String barcode;
  final String itemName;
  final String itemCode;
  final String? karat;

  const BarcodePrintScreen({
    super.key,
    required this.barcode,
    required this.itemName,
    required this.itemCode,
    this.karat,
  });

  /// A piece's number: its label is the print engine's, not this screen's.
  static final piece = RegExp(r'^KJ-\d{6,}$');

  @override
  State<BarcodePrintScreen> createState() => _BarcodePrintScreenState();
}

class _BarcodePrintScreenState extends State<BarcodePrintScreen> {
  BarcodeType _selectedType = BarcodeType.code128;
  int _labelCount = 1;
  bool _showItemCode = true;
  bool _showKarat = true;

  bool get _isPiece =>
      BarcodePrintScreen.piece.hasMatch(widget.itemCode) || BarcodePrintScreen.piece.hasMatch(widget.barcode);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_isPiece) {
      return Scaffold(
        appBar: AppBar(title: const Text('طباعة الباركود')),
        body: const AppEmptyView(
          key: Key('barcode-piece-refused'),
          title: 'القطعة لا تُطبع بطاقتها هنا',
          hint: 'بطاقة القطعة تُطبع من «القطع» أو «محطة ترميز القطع»: رمزها المربع، ورقاقتها تُكتب وتُقرأ.',
          icon: Icons.sell_outlined,
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('طباعة الباركود'),
        actions: [
          IconButton(icon: const Icon(Icons.print), tooltip: 'طباعة', onPressed: _printBarcode),
          IconButton(icon: const Icon(Icons.picture_as_pdf), tooltip: 'حفظ PDF', onPressed: _savePDF),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          Text(
                            widget.itemName,
                            style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.surfaceContainerLowest,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: theme.colorScheme.outlineVariant),
                            ),
                            child: BarcodeWidget(
                              barcode: _getBarcodeType(),
                              data: widget.barcode,
                              width: 300,
                              height: 100,
                              drawText: true,
                              color: theme.colorScheme.onSurface,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (_showItemCode) _buildInfoRow(theme, 'كود الصنف', widget.itemCode),
                          if (_showKarat && widget.karat != null)
                            _buildInfoRow(theme, 'العيار', '${widget.karat} قيراط'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildPrintOptions(theme),
                ],
              ),
            ),
          ),
          Material(
            color: theme.colorScheme.surfaceContainer,
            child: Padding(
              padding: const EdgeInsets.all(16),
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
                    child: FilledButton.icon(
                      key: const Key('barcode-print'),
                      onPressed: _printBarcode,
                      icon: const Icon(Icons.print),
                      label: Text('طباعة ($_labelCount)'),
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

  Widget _buildInfoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          Text(value, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildPrintOptions(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('خيارات الطباعة', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            DropdownButtonFormField<BarcodeType>(
              key: const Key('barcode-type'),
              initialValue: _selectedType,
              decoration: const InputDecoration(
                labelText: 'نوع الباركود',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.qr_code_2),
              ),
              items: const [
                DropdownMenuItem(value: BarcodeType.code128, child: Text('Code 128 (موصى به)')),
                DropdownMenuItem(value: BarcodeType.qrCode, child: Text('QR Code')),
                DropdownMenuItem(value: BarcodeType.code39, child: Text('Code 39')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _selectedType = value);
              },
            ),
            const SizedBox(height: 16),
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
                if (count != null && count > 0 && count <= 100) setState(() => _labelCount = count);
              },
            ),
            const SizedBox(height: 16),
            Text('المعلومات المعروضة', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            CheckboxListTile(
              title: const Text('كود الصنف'),
              value: _showItemCode,
              onChanged: (value) => setState(() => _showItemCode = value ?? true),
              dense: true,
            ),
            if (widget.karat != null)
              CheckboxListTile(
                title: const Text('العيار'),
                value: _showKarat,
                onChanged: (value) => setState(() => _showKarat = value ?? true),
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
      case BarcodeType.code39:
        return barcode_lib.Barcode.code39();
    }
  }

  Future<void> _printBarcode() async {
    try {
      Uint8List? cachedPdf;
      if (kIsWeb) {
        await Printing.sharePdf(bytes: await _generatePDF(), filename: 'barcode_${widget.itemCode}.pdf');
      } else {
        await Printing.layoutPdf(
          onLayout: (PdfPageFormat format) async => cachedPdf ??= await _generatePDF(),
          name: 'barcode_${widget.itemCode}',
        );
      }
      if (!mounted) return;
      AppFeedback.success(
          context, kIsWeb ? 'فُتح ملف الباركود: اطبعه من المتصفح.' : 'أُرسل الباركود إلى الطابعة.');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّرت طباعة الباركود');
    }
  }

  Future<void> _savePDF() async {
    try {
      await Printing.sharePdf(bytes: await _generatePDF(), filename: 'barcode_${widget.itemCode}.pdf');
      if (mounted) AppFeedback.success(context, 'حُفظ ملف PDF');
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّر حفظ ملف PDF');
    }
  }

  Future<Uint8List> _generatePDF() async {
    final pdf = pw.Document();
    final barcodeType = _getBarcodeType();

    // 50 x 30 mm labels, 4 a row, 8 rows a page
    const labelWidth = 50.0 * PdfPageFormat.mm;
    const labelHeight = 30.0 * PdfPageFormat.mm;
    const labelsPerPage = 4 * 8;

    for (var page = 0; page < (_labelCount / labelsPerPage).ceil(); page++) {
      final startIdx = page * labelsPerPage;
      final endIdx = (startIdx + labelsPerPage > _labelCount) ? _labelCount : startIdx + labelsPerPage;
      pdf.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a4,
          build: (context) => pw.Wrap(
            spacing: 2,
            runSpacing: 2,
            children: List.generate(endIdx - startIdx, (index) {
              return pw.Container(
                width: labelWidth,
                height: labelHeight,
                decoration: pw.BoxDecoration(border: pw.Border.all(color: PdfColors.grey300)),
                child: pw.Padding(
                  padding: const pw.EdgeInsets.all(4),
                  child: pw.Column(
                    mainAxisAlignment: pw.MainAxisAlignment.center,
                    children: [
                      pw.Text(widget.itemName,
                          style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold),
                          textAlign: pw.TextAlign.center,
                          maxLines: 1,
                          overflow: pw.TextOverflow.clip),
                      pw.SizedBox(height: 2),
                      pw.BarcodeWidget(
                        barcode: barcodeType,
                        data: widget.barcode,
                        width: labelWidth - 8,
                        height: 15 * PdfPageFormat.mm,
                        drawText: true,
                        textStyle: const pw.TextStyle(fontSize: 6),
                      ),
                      pw.Row(
                        mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                        children: [
                          if (_showItemCode) pw.Text(widget.itemCode, style: const pw.TextStyle(fontSize: 6)),
                          if (_showKarat && widget.karat != null)
                            pw.Text('${widget.karat}K', style: const pw.TextStyle(fontSize: 6)),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }),
          ),
        ),
      );
    }
    return pdf.save();
  }
}

enum BarcodeType { code128, qrCode, code39 }
