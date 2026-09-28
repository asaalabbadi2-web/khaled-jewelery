import 'dart:typed_data';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api_service.dart';
import '../pdf/invoice_pdf_builder.dart';
import '../providers/settings_provider.dart';

Future<bool> readPrintBlackAndWhite() async {
  final prefs = await SharedPreferences.getInstance();
  return !(prefs.getBool('print_in_color') ?? true);
}

Future<void> printInvoiceDirect({
  required BuildContext context,
  required Map<String, dynamic> invoice,
  String? paperSize,
  bool isArabic = true,
  bool? blackAndWhite,
}) async {
  SettingsProvider? sp;
  try {
    sp = context.read<SettingsProvider>();
    await sp.ensureLoadedForPrint();
  } catch (_) {}

  final bw = blackAndWhite ?? await readPrintBlackAndWhite();

  String filename() {
    final numStr = (invoice['invoice_type_id'] ?? '').toString().trim();
    final idStr = (invoice['id'] ?? '').toString().trim();
    final base = numStr.isNotEmpty
        ? 'invoice_$numStr'
        : (idStr.isNotEmpty ? 'invoice_$idStr' : 'invoice');
    return '$base.pdf';
  }

  try {
    await Printing.layoutPdf(
      name: filename(),
      onLayout: (format) async {
        final opts = InvoicePdfOptions(isArabic: isArabic, blackAndWhite: bw);
        return InvoicePdfBuilder.buildBytes(
          invoice: invoice,
          format: format,
          options: opts,
          settings: sp,
        );
      },
    );
  } catch (_) {
    // Let the caller handle UI messaging if needed.
    rethrow;
  }
}

Future<Uint8List> buildInvoicePdfBytes({
  required BuildContext context,
  required Map<String, dynamic> invoice,
  required PdfPageFormat format,
  bool isArabic = true,
}) async {
  SettingsProvider? sp;
  try {
    sp = context.read<SettingsProvider>();
    await sp.ensureLoadedForPrint();
  } catch (_) {}

  return InvoicePdfBuilder.buildBytes(
    invoice: invoice,
    format: format,
    options: InvoicePdfOptions(isArabic: isArabic),
    settings: sp,
  );
}

/// يشارك الفاتورة كـ PDF عبر تطبيقات التواصل (واتساب، تيليجرام، بريد...)
Future<void> shareInvoicePdf({
  required BuildContext context,
  required Map<String, dynamic> invoice,
  String? paperSize,
  bool isArabic = true,
}) async {
  SettingsProvider? sp;
  try {
    sp = context.read<SettingsProvider>();
    await sp.ensureLoadedForPrint();
  } catch (_) {}

  final format = (paperSize == 'A5')
      ? PdfPageFormat.a5
      : (paperSize == 'thermal' || paperSize == '80mm')
      ? const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 4 * PdfPageFormat.mm,
        )
      : PdfPageFormat.a4;

  final numStr = (invoice['invoice_type_id'] ?? '').toString().trim();
  final idStr = (invoice['id'] ?? '').toString().trim();
  final name = numStr.isNotEmpty
      ? 'invoice_$numStr'
      : (idStr.isNotEmpty ? 'invoice_$idStr' : 'invoice');

  final bytes = await InvoicePdfBuilder.buildBytes(
    invoice: invoice,
    format: format,
    options: InvoicePdfOptions(isArabic: isArabic),
    settings: sp,
  );

  if (kIsWeb) {
    // على الويب: استخدام Web Share API عبر share_plus
    final xFile = XFile.fromData(
      bytes,
      name: '$name.pdf',
      mimeType: 'application/pdf',
    );
    await Share.shareXFiles([xFile]);
  } else {
    // على الموبايل/ديسكتوب: نافذة مشاركة النظام
    await Printing.sharePdf(bytes: bytes, filename: '$name.pdf');
  }
}

/// يرفع الفاتورة PDF إلى الخادم مؤقتاً ثم يفتح واتساب بالرابط.
///
/// الخطوات:
///  1. توليد bytes من الفاتورة.
///  2. رفع الـ bytes إلى POST /api/temp-pdf  →  يُرجع {"token": "..."}.
///  3. بناء رابط عام: [apiBase]/temp-pdf/[token]
///  4. فتح https://wa.me/?text=... بالرابط المُضمَّن.
Future<void> shareInvoiceWhatsApp({
  required BuildContext context,
  required Map<String, dynamic> invoice,
  String? paperSize,
  bool isArabic = true,
}) async {
  SettingsProvider? sp;
  try {
    sp = context.read<SettingsProvider>();
    await sp.ensureLoadedForPrint();
  } catch (_) {}

  final format = (paperSize == 'A5')
      ? PdfPageFormat.a5
      : (paperSize == 'thermal' || paperSize == '80mm')
      ? const PdfPageFormat(
          80 * PdfPageFormat.mm,
          double.infinity,
          marginAll: 4 * PdfPageFormat.mm,
        )
      : PdfPageFormat.a4;

  // ── بناء PDF bytes ──────────────────────────────────────────────────────
  final bytes = await InvoicePdfBuilder.buildBytes(
    invoice: invoice,
    format: format,
    options: InvoicePdfOptions(isArabic: isArabic),
    settings: sp,
  );

  // ── رفع الملف إلى الخادم ───────────────────────────────────────────────
  final apiBase = ApiService.resolvedBaseUrl;
  final uploadUri = Uri.parse('$apiBase/temp-pdf');

  final response = await http.post(
    uploadUri,
    headers: await ApiService().sessionHeaders(contentType: 'application/pdf'),
    body: bytes,
  );

  if (response.statusCode != 201) {
    throw Exception('فشل رفع الملف (${response.statusCode})');
  }

  final body = response.body;
  final tokenMatch = RegExp(
    r'"token"\s*:\s*"([A-Za-z0-9_\-]+)"',
  ).firstMatch(body);
  if (tokenMatch == null) {
    throw Exception('استجابة غير متوقعة من الخادم');
  }
  final token = tokenMatch.group(1)!;

  // ── بناء رابط التنزيل ──────────────────────────────────────────────────
  final pdfUrl = '$apiBase/temp-pdf/$token';

  // ── بناء نص واتساب ──────────────────────────────────────────────────────
  final invoiceNum = (invoice['invoice_type_id'] ?? invoice['id'] ?? '')
      .toString();
  final customerName =
      (invoice['customer_name'] ?? invoice['supplier_name'] ?? '').toString();
  final total = (invoice['total_amount'] ?? invoice['net_weight'] ?? '')
      .toString();

  final textLines = <String>[
    isArabic ? 'فاتورة رقم: $invoiceNum' : 'Invoice #$invoiceNum',
    if (customerName.isNotEmpty)
      isArabic ? 'العميل: $customerName' : 'Customer: $customerName',
    if (total.isNotEmpty) isArabic ? 'الإجمالي: $total' : 'Total: $total',
    '',
    isArabic ? '📎 رابط الفاتورة:' : '📎 Invoice link:',
    pdfUrl,
  ];

  final text = Uri.encodeComponent(textLines.join('\n'));
  final waUrl = Uri.parse('https://wa.me/?text=$text');

  if (await canLaunchUrl(waUrl)) {
    await launchUrl(waUrl, mode: LaunchMode.externalApplication);
  } else {
    throw Exception(isArabic ? 'تعذر فتح واتساب' : 'Could not open WhatsApp');
  }
}
