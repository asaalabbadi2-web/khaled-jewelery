import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../pdf/voucher_pdf_builder.dart';
import '../providers/settings_provider.dart';

/// شاشة معاينة السند (Legacy) — تستخدم نفس PDF builder الجديد.
class VoucherPreviewScreen extends StatefulWidget {
  final Map<String, dynamic> voucherData;
  final String voucherType; // 'receipt' or 'payment'

  const VoucherPreviewScreen({
    super.key,
    required this.voucherData,
    required this.voucherType,
  });

  @override
  State<VoucherPreviewScreen> createState() => _VoucherPreviewScreenState();
}

class _VoucherPreviewScreenState extends State<VoucherPreviewScreen> {
  late final Future<({String paperSize, String orientation})> _prefsFuture;

  @override
  void initState() {
    super.initState();
    _prefsFuture = _loadPrintPrefs();
  }

  bool get _isReceipt => widget.voucherType == 'receipt';
  String get _voucherTitle => _isReceipt ? 'سند قبض' : 'سند صرف';

  String _voucherPdfFilename() {
    final id = (widget.voucherData['id'] ?? '').toString();
    final number = (widget.voucherData['voucher_number'] ?? '').toString();
    final base = number.trim().isNotEmpty
        ? number.trim()
        : (id.isNotEmpty ? 'voucher_$id' : 'voucher');
    return '$base.pdf';
  }

  Future<({String paperSize, String orientation})> _loadPrintPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPaper = prefs.getString('printer_paper_size_v1') ?? 'A4';
    return (paperSize: storedPaper, orientation: 'portrait');
  }

  Future<Uint8List> _buildVoucherPdfBytes(PdfPageFormat format) async {
    SettingsProvider? sp;
    try {
      sp = context.read<SettingsProvider>();
      await sp.ensureLoadedForPrint();
    } catch (_) {}

    final prefs = await SharedPreferences.getInstance();
    final bw = !(prefs.getBool('print_in_color') ?? true);
    return VoucherPdfBuilder.buildBytes(
      voucher: widget.voucherData,
      format: format,
      options: VoucherPdfOptions(
        isArabic: true,
        includeAccountLines: false,
        blackAndWhite: bw,
      ),
      settings: sp,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('$_voucherTitle - معاينة')),
      body: FutureBuilder<({String paperSize, String orientation})>(
        future: _prefsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final prefs = snapshot.data!;
          final initialFormat = VoucherPdfBuilder.pageFormatFromSettings(
            paperSize: prefs.paperSize,
            orientation: prefs.orientation,
          );

          return PdfPreview(
            initialPageFormat: initialFormat,
            canChangePageFormat: true,
            canChangeOrientation: false,
            allowPrinting: true,
            allowSharing: true,
            pdfFileName: _voucherPdfFilename(),
            build: (format) => _buildVoucherPdfBytes(format),
          );
        },
      ),
    );
  }
}
