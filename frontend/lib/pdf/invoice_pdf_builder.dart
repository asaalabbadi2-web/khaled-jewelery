import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../pdf/pdf_sar_cache.dart';
import '../pdf/pdf_text_utils.dart';
import '../providers/settings_provider.dart';
import '../utils/invoice_type_label.dart';

class InvoicePdfOptions {
  final bool isArabic;
  final bool blackAndWhite;

  const InvoicePdfOptions({this.isArabic = true, this.blackAndWhite = false});
}

class InvoicePdfBuilder {
  static PdfPageFormat pageFormatFromSettings({
    required String paperSize,
    required String orientation,
  }) {
    PdfPageFormat base;
    switch (paperSize) {
      case 'A5':
        base = PdfPageFormat.a5;
        break;
      case 'Letter':
        base = PdfPageFormat.letter;
        break;
      case 'Thermal':
        return const PdfPageFormat(80 * PdfPageFormat.mm, double.infinity);
      default:
        base = PdfPageFormat.a4;
    }

    if (orientation == 'landscape') return base.landscape;
    return base;
  }

  static Future<Uint8List> buildBytes({
    required Map<String, dynamic> invoice,
    required PdfPageFormat format,
    required InvoicePdfOptions options,
    SettingsProvider? settings,
  }) async {
    // ═══ Main thread: lazy-load assets into cache on first print ═══
    await Future.wait([
      PdfSarCache.ensureFontBytes(),
      PdfSarCache.ensureDefaultLogo(),
    ]);

    final fontRegBytes = PdfSarCache.fontRegBytes!;
    final fontBoldBytes = PdfSarCache.fontBoldBytes!;

    const amberColor = PdfColor.fromInt(0xFF8B6914);
    const darkColor = PdfColor.fromInt(0xFF1A1A1A);
    final isNewSar = settings?.currencyIsNewSar == true;
    if (isNewSar) {
      await Future.wait([
        PdfSarCache.tinted(amberColor),
        PdfSarCache.tinted(darkColor),
      ]);
    }
    // In B&W mode always use the dark tint (gold would print as faint gray).
    final sarGoldBytes = isNewSar ? PdfSarCache.tintedBytes(options.blackAndWhite ? darkColor : amberColor) : null;
    final sarTextBytes = isNewSar ? PdfSarCache.tintedBytes(darkColor) : null;

    final showLogoFlag = settings?.showCompanyLogo ?? true;
    Uint8List? logoBytes;
    if (showLogoFlag) {
      final logoB64 = (settings?.settings['company_logo_base64'] ?? '')
          .toString()
          .trim();
      if (logoB64.isNotEmpty) {
        try {
          var p = logoB64;
          final ci = p.indexOf(',');
          if (p.startsWith('data:') && ci >= 0) p = p.substring(ci + 1);
          final raw = base64Decode(p);
          if (raw.isNotEmpty) {
            logoBytes = PdfSarCache.resizePng(raw, 128) ?? raw;
          }
        } catch (_) {}
      }
      if (logoBytes == null) {
        final raw =
            PdfSarCache.defaultLogoBytes ??
            (await rootBundle.load('assets/KHGL.png')).buffer.asUint8List();
        logoBytes = PdfSarCache.resizePng(raw, 128) ?? raw;
      }
    }

    final cashSym = settings?.currencySymbolText ?? 'ر.س';
    final coName = (settings?.companyName.trim() ?? '').isNotEmpty
        ? settings!.companyName.trim()
        : (options.isArabic ? 'خالد للمجوهرات' : 'Khaled Jewelry');
    final coCr = settings?.companyCrNumber.trim() ?? '';
    final coVat = settings?.companyTaxNumber.trim() ?? '';
    final coPhone = settings?.companyPhone.trim() ?? '';
    final coAddr = settings?.companyAddress.trim() ?? '';

    await Future.delayed(Duration.zero);

    // Build fonts from cached bytes.
    pw.Font fontReg;
    pw.Font fontBold;
    try {
      fontReg = pw.Font.ttf(fontRegBytes.buffer.asByteData());
      fontBold = pw.Font.ttf(fontBoldBytes.buffer.asByteData());
    } catch (_) {
      fontReg = pw.Font.helvetica();
      fontBold = pw.Font.helveticaBold();
    }
    if (options.blackAndWhite && logoBytes != null) {
      logoBytes = PdfSarCache.toGrayscalePng(logoBytes);
    }
    pw.MemoryImage? logoImage = logoBytes != null
        ? pw.MemoryImage(logoBytes)
        : null;
    pw.ImageProvider? sarGold = sarGoldBytes != null
        ? pw.MemoryImage(sarGoldBytes)
        : null;
    pw.ImageProvider? sarText = sarTextBytes != null
        ? pw.MemoryImage(sarTextBytes)
        : null;
    final cashCurrencySymbol = cashSym;
    final companyName = coName;
    final companyCr = coCr;
    final companyVat = coVat;
    final companyPhone = coPhone;
    final companyAddr = coAddr;

    double toDouble(dynamic v) {
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? 0.0;
    }

    String fmtDate(dynamic raw) {
      if (raw == null) return '';
      final s = raw.toString();
      if (s.isEmpty) return '';
      final dt = DateTime.tryParse(s);
      if (dt == null) return s;
      // Force Western digits (stable for RTL PDFs)
      return DateFormat('yyyy-MM-dd', 'en').format(dt);
    }

    String weight(dynamic v) => toDouble(v).toStringAsFixed(3);

    String safeStr(dynamic v) => (v ?? '').toString().trim();

    final invoiceType = safeStr(invoice['invoice_type']);
    final invoiceNumber = (safeStr(invoice['invoice_type_id']).isNotEmpty)
        ? '#${safeStr(invoice['invoice_type_id'])}'
        : (safeStr(invoice['id']).isNotEmpty)
        ? '#${safeStr(invoice['id'])}'
        : '#—';

    final dateText = fmtDate(invoice['date']);
    final printDate = fmtDate(DateTime.now().toIso8601String());

    final customerName = safeStr(invoice['customer_name']);
    final supplierName = safeStr(invoice['supplier_name']);
    final partyName = customerName.isNotEmpty ? customerName : supplierName;
    final partyLabel = customerName.isNotEmpty
        ? (options.isArabic ? 'العميل' : 'Customer')
        : (options.isArabic ? 'المورد' : 'Supplier');

    final total = toDouble(invoice['total']);
    final tax = toDouble(invoice['total_tax']);
    final subtotal = (total - tax);

    // Weight summary
    final totalWeight = toDouble(invoice['total_weight']);

    // Per-karat weights from items
    final itemsRaw = invoice['items'];
    final items = itemsRaw is List
        ? itemsRaw
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList()
        : <Map<String, dynamic>>[];

    final totalsByKarat = <String, double>{};
    double computedTotalWeight = 0.0;
    for (final item in items) {
      final karat = safeStr(item['karat']);
      final qty = toDouble(item['quantity']);
      final qtySafe = qty <= 0 ? 1.0 : qty;

      final totalW = toDouble(item['total_weight']);
      final perItemW = toDouble(item['weight']);
      final fallbackW = toDouble(item['weight'] ?? item['total_weight']);
      final lineW = totalW > 0
          ? totalW
          : (perItemW > 0 ? perItemW * qtySafe : fallbackW);
      if (lineW <= 0) continue;

      computedTotalWeight += lineW;
      if (karat.isNotEmpty) {
        totalsByKarat[karat] = (totalsByKarat[karat] ?? 0) + lineW;
      }
    }

    final effectiveTotalWeight = totalWeight > 0
        ? totalWeight
        : computedTotalWeight;

    // All assets captured from main thread — no rootBundle / dart:ui here.

    // Theme colors — B&W palette swaps amber tones for strong grays.
    final gold   = options.blackAndWhite ? const PdfColor.fromInt(0xFF1A1A1A) : const PdfColor.fromInt(0xFF8B6914);
    final goldMid = options.blackAndWhite ? const PdfColor.fromInt(0xFF333333) : const PdfColor.fromInt(0xFFA07820);
    final goldBg  = options.blackAndWhite ? const PdfColor.fromInt(0xFFF0F0F0) : const PdfColor.fromInt(0xFFFBF7EE);
    final border  = options.blackAndWhite ? const PdfColor.fromInt(0xFF888888) : const PdfColor.fromInt(0xFFE8D899);
    const text = PdfColor.fromInt(0xFF1A1A1A);
    const muted = PdfColor.fromInt(0xFF444444);

    // Widget builder for a cash amount with optional SAR image inline.
    pw.Widget buildAmountWidget(
      double amount, {
      double size = 11,
      PdfColor color = text,
    }) {
      final numStr = NumberFormat(
        '#,##0.00',
        options.isArabic ? 'ar' : 'en',
      ).format(amount);
      final sarImg = (color == gold || color == goldMid) ? sarGold : sarText;
      if (sarImg != null) {
        final img = pw.Image(sarImg, width: size * 0.72, height: size);
        final num = pw.Text(
          options.isArabic ? pdfVisualArabic(numStr) : numStr,
          textDirection: pw.TextDirection.ltr,
          style: pw.TextStyle(fontSize: size, color: color),
        );
        // Arabic: symbol LEFT of number (img first in LTR row).
        // English: number LEFT of symbol (num first in LTR row).
        return pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: options.isArabic
              ? [img, pw.SizedBox(width: 2), num]
              : [num, pw.SizedBox(width: 2), img],
        );
      }
      final sym = cashCurrencySymbol;
      final full = options.isArabic
          ? '${pdfVisualArabic(sym)} ${pdfVisualArabic(numStr)}'
          : '$numStr $sym';
      return pw.Text(
        full,
        textDirection: pw.TextDirection.ltr,
        style: pw.TextStyle(fontSize: size, color: color),
      );
    }

    String ar(String s) => options.isArabic ? pdfVisualArabic(s) : s;

    pw.Widget headerInfoLine(String label, String value) {
      final l = options.isArabic ? ar(label) : label;
      final v = options.isArabic ? ar(value) : value;

      final labelText = pw.Text(
        l,
        style: pw.TextStyle(fontSize: 8, color: muted),
        textDirection: pw.TextDirection.ltr,
        maxLines: 1,
      );

      final colonText = pw.Text(
        ':',
        style: pw.TextStyle(fontSize: 8, color: muted),
        textDirection: pw.TextDirection.ltr,
        maxLines: 1,
      );

      final valueText = pw.Text(
        v,
        style: pw.TextStyle(fontSize: 8, color: gold),
        textDirection: pw.TextDirection.ltr,
        textAlign: options.isArabic ? pw.TextAlign.right : pw.TextAlign.left,
        maxLines: 1,
        softWrap: false,
        overflow: pw.TextOverflow.clip,
      );

      return pw.Padding(
        padding: const pw.EdgeInsets.only(top: 2),
        child: pw.Container(
          width: double.infinity,
          child: pw.Row(
            mainAxisSize: pw.MainAxisSize.max,
            mainAxisAlignment: options.isArabic
                ? pw.MainAxisAlignment.end
                : pw.MainAxisAlignment.start,
            children: options.isArabic
                ? [
                    // Pin label/colon to the RIGHT, value to the LEFT.
                    pw.Expanded(
                      child: pw.Align(
                        alignment: pw.Alignment.centerRight,
                        child: valueText,
                      ),
                    ),
                    pw.SizedBox(width: 6),
                    colonText,
                    pw.SizedBox(width: 6),
                    labelText,
                  ]
                : [
                    labelText,
                    pw.SizedBox(width: 6),
                    colonText,
                    pw.SizedBox(width: 6),
                    pw.Expanded(child: valueText),
                  ],
          ),
        ),
      );
    }

    pw.Widget buildHeader() {
      final headerTitle = options.isArabic
          ? ar(invoiceType.isNotEmpty ? 'فاتورة ${invoiceTypeLabel(invoice)}' : 'فاتورة')
          : (invoiceType.isNotEmpty ? 'Invoice ($invoiceType)' : 'Invoice');

      final right = pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.end,
        children: [
          pw.Row(
            mainAxisSize: pw.MainAxisSize.min,
            children: [
              if (logoImage != null) ...[
                pw.Container(
                  width: 36,
                  height: 36,
                  alignment: pw.Alignment.center,
                  child: pw.Image(logoImage, fit: pw.BoxFit.contain),
                ),
                pw.SizedBox(width: 6),
              ],
              pw.Text(
                options.isArabic ? ar(companyName) : companyName,
                style: pw.TextStyle(
                  fontSize: 14,
                  fontWeight: pw.FontWeight.bold,
                  color: gold,
                ),
                textDirection: pw.TextDirection.ltr,
              ),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Container(height: 0.7, color: border),
          // Match voucher layout/order (top -> bottom): CR, VAT, Phone, Address
          if (companyCr.trim().isNotEmpty)
            headerInfoLine(options.isArabic ? 'سجل تجاري' : 'CR', companyCr),
          if (companyVat.trim().isNotEmpty)
            headerInfoLine(
              options.isArabic ? 'الرقم الضريبي' : 'VAT No',
              companyVat,
            ),
          if (companyPhone.trim().isNotEmpty)
            headerInfoLine(options.isArabic ? 'هاتف' : 'Phone', companyPhone),
          if (companyAddr.trim().isNotEmpty)
            headerInfoLine(
              options.isArabic ? 'العنوان' : 'Address',
              companyAddr,
            ),
        ],
      );

      final center = pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.center,
        children: [
          pw.Text(
            headerTitle,
            style: pw.TextStyle(
              fontSize: 24,
              fontWeight: pw.FontWeight.bold,
              color: gold,
            ),
            textDirection: pw.TextDirection.ltr,
          ),
          pw.SizedBox(height: 3),
          pw.Container(height: 1, width: 58, color: goldMid),
          pw.SizedBox(height: 8),
          pw.BarcodeWidget(
            barcode: pw.Barcode.qrCode(),
            data: [
              'invoice_no=$invoiceNumber',
              if (dateText.isNotEmpty) 'date=$dateText',
              if (invoiceType.isNotEmpty) 'type=$invoiceType',
              if (partyName.isNotEmpty) 'party=$partyName',
            ].join(';'),
            width: 60,
            height: 60,
            color: gold,
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            options.isArabic ? ar('تحقق من الفاتورة') : 'Scan to verify',
            style: pw.TextStyle(fontSize: 6.5, color: muted),
            textDirection: pw.TextDirection.ltr,
          ),
        ],
      );

      pw.Widget metaLine(String label, String value) {
        final l = options.isArabic ? ar(label) : label;
        final v = options.isArabic ? ar(value) : value;
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              l,
              style: pw.TextStyle(fontSize: 7.5, color: muted),
              textDirection: pw.TextDirection.ltr,
            ),
            pw.SizedBox(height: 1),
            pw.Text(
              v,
              style: pw.TextStyle(
                fontSize: 10,
                fontWeight: pw.FontWeight.bold,
                color: text,
              ),
              textDirection: pw.TextDirection.ltr,
              maxLines: 1,
            ),
          ],
        );
      }

      final left = pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          metaLine(
            options.isArabic ? 'رقم الفاتورة' : 'Invoice No.',
            invoiceNumber,
          ),
          pw.SizedBox(height: 6),
          metaLine(
            options.isArabic ? 'التاريخ' : 'Date',
            dateText.isEmpty ? '—' : dateText,
          ),
          if (partyName.isNotEmpty) ...[
            pw.SizedBox(height: 6),
            metaLine(partyLabel, partyName),
          ],
        ],
      );

      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Container(
            height: 4,
            decoration: options.blackAndWhite
                ? const pw.BoxDecoration(color: PdfColor.fromInt(0xFF1A1A1A))
                : pw.BoxDecoration(
                    gradient: pw.LinearGradient(
                      colors: [
                        PdfColor.fromInt(0xFF8B6914),
                        PdfColor.fromInt(0xFFC9A84C),
                        PdfColor.fromInt(0xFFE8C97A),
                        PdfColor.fromInt(0xFFC9A84C),
                        PdfColor.fromInt(0xFF8B6914),
                      ],
                    ),
                  ),
          ),
          pw.Container(
            padding: const pw.EdgeInsets.fromLTRB(14, 12, 14, 10),
            decoration: pw.BoxDecoration(
              color: goldBg,
              border: pw.Border(
                bottom: pw.BorderSide(color: border, width: 1.0),
              ),
            ),
            child: pw.Stack(
              children: [
                // Ensure Stack has a concrete size; otherwise a Stack with only
                // Positioned children may end up with zero size and fail layout.
                pw.SizedBox(height: 120),
                pw.Positioned(
                  top: 0,
                  right: 0,
                  child: pw.SizedBox(width: 170, child: right),
                ),
                pw.Positioned(
                  top: 0,
                  left: 170,
                  right: 170,
                  child: pw.Align(
                    alignment: pw.Alignment.topCenter,
                    child: center,
                  ),
                ),
                pw.Positioned(
                  top: 0,
                  left: 0,
                  child: pw.SizedBox(width: 170, child: left),
                ),
              ],
            ),
          ),
        ],
      );
    }

    pw.Widget card({required String title, required pw.Widget child}) {
      final t = options.isArabic ? ar(title) : title;
      return pw.Container(
        padding: const pw.EdgeInsets.all(12),
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          borderRadius: pw.BorderRadius.circular(8),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Align(
              alignment: options.isArabic
                  ? pw.Alignment.centerRight
                  : pw.Alignment.centerLeft,
              child: pw.Text(
                t,
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: gold,
                ),
                textDirection: pw.TextDirection.ltr,
                textAlign: options.isArabic
                    ? pw.TextAlign.right
                    : pw.TextAlign.left,
              ),
            ),
            pw.SizedBox(height: 6),
            child,
          ],
        ),
      );
    }

    pw.Widget buildHeroTotal() {
      final label = options.isArabic
          ? ar('الإجمالي النهائي')
          : 'Grand Total';

      return pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: pw.BoxDecoration(
          color: PdfColors.white,
          border: pw.Border.all(color: border, width: 0.8),
          borderRadius: pw.BorderRadius.circular(10),
        ),
        child: pw.Align(
          alignment: options.isArabic
              ? pw.Alignment.centerRight
              : pw.Alignment.centerLeft,
          child: pw.Padding(
            padding: options.isArabic
                ? const pw.EdgeInsets.only(right: 6)
                : const pw.EdgeInsets.only(left: 6),
            child: pw.Column(
              crossAxisAlignment: options.isArabic
                  ? pw.CrossAxisAlignment.end
                  : pw.CrossAxisAlignment.start,
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  label,
                  style: pw.TextStyle(
                    fontSize: 12,
                    fontWeight: pw.FontWeight.bold,
                    color: gold,
                  ),
                  textDirection: pw.TextDirection.ltr,
                ),
                pw.SizedBox(height: 4),
                buildAmountWidget(total, size: 28, color: gold),
              ],
            ),
          ),
        ),
      );
    }

    pw.Widget buildGoldSummary() {
      final uniqueKarats = <String>{
        for (final item in items)
          if (safeStr(item['karat']).isNotEmpty) safeStr(item['karat']),
      };

      final karatText = uniqueKarats.isEmpty
          ? '—'
          : (uniqueKarats.length == 1)
          ? uniqueKarats.first
          : (options.isArabic ? ar('متعدد') : 'Mixed');

      pw.Widget line(String label, {String? value, pw.Widget? valueWidget}) {
        final l = options.isArabic ? ar(label) : label;
        final v = value == null ? '' : (options.isArabic ? ar(value) : value);
        return pw.Padding(
          padding: const pw.EdgeInsets.only(top: 2),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: options.isArabic
                ? [
                    (valueWidget ??
                        pw.Text(v, textDirection: pw.TextDirection.ltr)),
                    pw.Text(l, textDirection: pw.TextDirection.ltr),
                  ]
                : [
                    pw.Text(l, textDirection: pw.TextDirection.ltr),
                    (valueWidget ??
                        pw.Text(v, textDirection: pw.TextDirection.ltr)),
                  ],
          ),
        );
      }

      final weightValueWidget = (effectiveTotalWeight > 0)
          ? pw.Row(
              mainAxisSize: pw.MainAxisSize.min,
              children: options.isArabic
                  ? [
                      // For RTL layout, place the unit first so the number
                      // sits on the far right visually: 61.320 جم
                      pw.Text(ar('جم'), textDirection: pw.TextDirection.ltr),
                      pw.SizedBox(width: 4),
                      pw.Text(
                        weight(effectiveTotalWeight),
                        textDirection: pw.TextDirection.ltr,
                      ),
                    ]
                  : [
                      pw.Text(
                        weight(effectiveTotalWeight),
                        textDirection: pw.TextDirection.ltr,
                      ),
                      pw.SizedBox(width: 4),
                      pw.Text('g', textDirection: pw.TextDirection.ltr),
                    ],
            )
          : pw.Text('—', textDirection: pw.TextDirection.ltr);

      return card(
        title: options.isArabic ? 'تفاصيل الذهب' : 'Gold Details',
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            line(
              options.isArabic ? 'إجمالي الوزن' : 'Total Weight',
              valueWidget: weightValueWidget,
            ),
            line(options.isArabic ? 'العيار' : 'Karat', value: karatText),
          ],
        ),
      );
    }

    pw.Widget buildTotals() {
      pw.Widget rowW(
        String label,
        pw.Widget valueWidget, {
        bool strong = false,
      }) {
        final l = options.isArabic ? ar(label) : label;
        return pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: options.isArabic
                ? [
                    valueWidget,
                    pw.Text(
                      l,
                      style: pw.TextStyle(
                        fontWeight: strong
                            ? pw.FontWeight.bold
                            : pw.FontWeight.normal,
                      ),
                      textDirection: pw.TextDirection.ltr,
                    ),
                  ]
                : [
                    pw.Text(
                      l,
                      style: pw.TextStyle(
                        fontWeight: strong
                            ? pw.FontWeight.bold
                            : pw.FontWeight.normal,
                      ),
                      textDirection: pw.TextDirection.ltr,
                    ),
                    valueWidget,
                  ],
          ),
        );
      }

      return card(
        title: options.isArabic ? 'الإجماليات' : 'Totals',
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            rowW(
              options.isArabic ? 'المجموع الفرعي' : 'Subtotal',
              buildAmountWidget(subtotal),
            ),
            rowW(options.isArabic ? 'الضريبة' : 'Tax', buildAmountWidget(tax)),
            pw.SizedBox(height: 6),
            pw.Container(
              height: 0.9,
              color: const PdfColor.fromInt(0xFFDDDDDD),
              margin: const pw.EdgeInsets.only(top: 2, bottom: 6),
            ),
            rowW(
              options.isArabic ? 'الإجمالي' : 'Total',
              buildAmountWidget(total),
              strong: true,
            ),
          ],
        ),
      );
    }

    pw.Widget buildItemsTable() {
      const headerTextColor = PdfColor.fromInt(0xFF3A3A3A);

      String formatKaratCell(String raw) {
        final k = safeStr(raw);
        if (k.isEmpty) return '—';

        // Prefer a compact suffix to avoid RTL/BiDi confusion in PDFs.
        // Examples: 21k, 18k
        final digits = RegExp(r'\d+').firstMatch(k)?.group(0);
        if (digits != null && digits.isNotEmpty) return '${digits}k';

        // If already contains k/K somewhere, normalize to lowercase k.
        if (RegExp(r'[kK]').hasMatch(k)) {
          return k.replaceAll('K', 'k');
        }

        return k;
      }

      pw.Widget cell(String s, {bool header = false}) {
        final t = options.isArabic ? ar(s) : s;
        return pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: pw.Text(
            t,
            style: pw.TextStyle(
              fontSize: header ? 10.5 : 10,
              fontWeight: header ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: header ? headerTextColor : PdfColor.fromInt(0xFF222222),
            ),
            textDirection: pw.TextDirection.ltr,
            textAlign: pw.TextAlign.center,
            maxLines: 2,
          ),
        );
      }

      double lineNet(Map<String, dynamic> item) {
        final candidates = <dynamic>[
          item['net'],
          item['net_amount'],
          item['net_total'],
          item['subtotal'],
          item['line_total'],
          item['total'],
          item['amount'],
        ];
        for (final c in candidates) {
          final v = toDouble(c);
          if (v != 0) return v;
        }
        return 0.0;
      }

      double lineWeight(Map<String, dynamic> item) {
        final qty = toDouble(item['quantity']);
        final qtySafe = qty <= 0 ? 1.0 : qty;

        final totalW = toDouble(item['total_weight']);
        final perItemW = toDouble(item['weight']);
        final fallbackW = toDouble(item['weight'] ?? item['total_weight']);
        final w = totalW > 0
            ? totalW
            : (perItemW > 0 ? perItemW * qtySafe : fallbackW);
        return w;
      }

      String moneyValue(dynamic v) => toDouble(v).toStringAsFixed(2);

      const colCount = 7;
      final colWidths = <int, pw.TableColumnWidth>{
        0: const pw.FlexColumnWidth(0.7),
        1: const pw.FlexColumnWidth(3),
        2: const pw.FlexColumnWidth(1.0),
        3: const pw.FlexColumnWidth(0.9),
        4: const pw.FlexColumnWidth(1.2),
        5: const pw.FlexColumnWidth(1.3),
        6: const pw.FlexColumnWidth(1.4),
      };

      final headers = <pw.Widget>[
        cell('#', header: true),
        cell(options.isArabic ? 'اسم الصنف' : 'Item Name', header: true),
        cell(options.isArabic ? 'العيار' : 'Karat', header: true),
        cell(options.isArabic ? 'العدد' : 'Qty', header: true),
        cell(options.isArabic ? 'الوزن' : 'Weight', header: true),
        cell(options.isArabic ? 'سعر الجرام' : 'Price/g', header: true),
        cell(options.isArabic ? 'الإجمالي' : 'Total', header: true),
      ];

      return pw.Table(
        border: pw.TableBorder(
          top: pw.BorderSide(color: border, width: 0.8),
          bottom: pw.BorderSide(color: border, width: 0.8),
          horizontalInside: pw.BorderSide(color: border, width: 0.35),
        ),
        columnWidths: options.isArabic
            ? <int, pw.TableColumnWidth>{
                for (var i = 0; i < colCount; i++)
                  i: colWidths[(colCount - 1) - i]!,
              }
            : colWidths,
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(
              color: PdfColors.white,
              border: pw.Border(
                bottom: pw.BorderSide(color: goldMid, width: 0.8),
              ),
            ),
            children: options.isArabic ? headers.reversed.toList() : headers,
          ),
          ...items.asMap().entries.map((e) {
            final idx = e.key;
            final item = e.value;
            final name = safeStr(item['name'] ?? item['item_name']);
            final karat = safeStr(item['karat']);
            final qty = toDouble(item['quantity']);
            final qtyInt = (qty <= 0 ? 1 : qty.round());

            final wValue = lineWeight(item);
            final w = (wValue > 0) ? weight(wValue) : '—';

            final netValue = lineNet(item);
            final netText = netValue != 0 ? moneyValue(netValue) : '—';
            final pricePerGram = (wValue > 0 && netValue != 0)
                ? (netValue / wValue)
                : 0.0;
            final priceText = (wValue > 0 && netValue != 0)
                ? moneyValue(pricePerGram)
                : '—';

            final cells = <pw.Widget>[
              cell('${idx + 1}'),
              cell(name.isEmpty ? '—' : name),
              cell(formatKaratCell(karat)),
              cell(qtyInt.toString()),
              cell(w),
              cell(priceText),
              cell(netText),
            ];

            return pw.TableRow(
              decoration: pw.BoxDecoration(
                color: (idx % 2 == 0)
                    ? PdfColors.white
                    : PdfColor.fromInt(0xFFFCFAF5),
              ),
              children: options.isArabic ? cells.reversed.toList() : cells,
            );
          }),
        ],
      );
    }

    pw.Widget buildSignatures() {
      final c = PdfColor.fromInt(0xFFDDDDDD);
      final labelCustomer = options.isArabic
          ? ar('توقيع العميل')
          : 'Customer Signature';
      final labelSeller = options.isArabic
          ? ar('توقيع البائع')
          : 'Seller Signature';

      pw.Widget dottedLine() {
        return pw.Container(
          height: 1.6,
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: List.generate(
              24,
              (_) => pw.Container(
                width: 1.3,
                height: 1.3,
                decoration: pw.BoxDecoration(
                  color: c,
                  shape: pw.BoxShape.circle,
                ),
              ),
            ),
          ),
        );
      }

      pw.Widget block(String label) {
        return pw.Expanded(
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: [
              pw.SizedBox(height: 6),
              dottedLine(),
              pw.SizedBox(height: 4),
              pw.Text(
                label,
                style: pw.TextStyle(fontSize: 8.5, color: muted),
                textDirection: pw.TextDirection.ltr,
                textAlign: pw.TextAlign.center,
              ),
            ],
          ),
        );
      }

      return pw.Container(
        margin: const pw.EdgeInsets.only(top: 12),
        child: pw.Row(
          children: options.isArabic
              ? [
                  block(labelSeller),
                  pw.SizedBox(width: 24),
                  block(labelCustomer),
                ]
              : [
                  block(labelCustomer),
                  pw.SizedBox(width: 24),
                  block(labelSeller),
                ],
        ),
      );
    }

    pw.Widget buildFooter() {
      final left = options.isArabic
          ? ar('تاريخ الطباعة: $printDate')
          : 'Printed: $printDate';
      final right = options.isArabic
          ? ar('شكراً لتعاملكم مع $companyName')
          : 'Thank you for choosing $companyName';

      return pw.Container(
        margin: const pw.EdgeInsets.only(top: 16),
        padding: const pw.EdgeInsets.only(top: 10),
        decoration: const pw.BoxDecoration(
          border: pw.Border(
            top: pw.BorderSide(color: PdfColor.fromInt(0xFFDDDDDD)),
          ),
        ),
        child: pw.Row(
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              left,
              style: pw.TextStyle(fontSize: 7.5, color: muted),
              textDirection: pw.TextDirection.ltr,
            ),
            pw.Text(
              right,
              style: pw.TextStyle(fontSize: 7.5, color: muted),
              textDirection: pw.TextDirection.ltr,
              textAlign: pw.TextAlign.right,
            ),
          ],
        ),
      );
    }

    final title = options.isArabic ? 'فاتورة' : 'Invoice';
    final doc = pw.Document(title: title, author: companyName);

    try {
      doc.addPage(
        pw.MultiPage(
          pageFormat: format,
          margin: const pw.EdgeInsets.fromLTRB(
            14 * PdfPageFormat.mm,
            12 * PdfPageFormat.mm,
            14 * PdfPageFormat.mm,
            12 * PdfPageFormat.mm,
          ),
          theme: pw.ThemeData.withFont(base: fontReg, bold: fontBold),
          footer: (_) => buildFooter(),
          build: (ctx) => [
            buildHeader(),
            pw.SizedBox(height: 14),
            buildHeroTotal(),
            pw.SizedBox(height: 14),
            pw.Align(
              alignment: options.isArabic
                  ? pw.Alignment.centerRight
                  : pw.Alignment.centerLeft,
              child: pw.Text(
                options.isArabic ? ar('الأصناف') : 'Items',
                style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: gold,
                ),
                textDirection: pw.TextDirection.ltr,
                textAlign: options.isArabic
                    ? pw.TextAlign.right
                    : pw.TextAlign.left,
              ),
            ),
            pw.SizedBox(height: 6),
            buildItemsTable(),
            pw.SizedBox(height: 12),
            // Under-table section: gold details on the right, totals on the left.
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: options.isArabic
                  ? [
                      pw.Expanded(
                        child: pw.Align(
                          alignment: pw.Alignment.topLeft,
                          child: pw.Container(width: 250, child: buildTotals()),
                        ),
                      ),
                      pw.SizedBox(width: 10),
                      pw.Container(width: 1, height: 92, color: border),
                      pw.SizedBox(width: 10),
                      pw.Expanded(
                        child: pw.Align(
                          alignment: pw.Alignment.topRight,
                          child: buildGoldSummary(),
                        ),
                      ),
                    ]
                  : [
                      pw.Expanded(
                        child: pw.Align(
                          alignment: pw.Alignment.topLeft,
                          child: buildGoldSummary(),
                        ),
                      ),
                      pw.SizedBox(width: 10),
                      pw.Container(width: 1, height: 92, color: border),
                      pw.SizedBox(width: 10),
                      pw.Expanded(
                        child: pw.Align(
                          alignment: pw.Alignment.topRight,
                          child: pw.Container(width: 250, child: buildTotals()),
                        ),
                      ),
                    ],
            ),
            buildSignatures(),
          ],
        ),
      );

      return doc.save();
    } catch (e, st) {
      // Log for devtool/console debugging (especially on web).
      // ignore: avoid_print
      print('InvoicePdfBuilder failed: $e\n$st');

      final errDoc = pw.Document(title: title, author: companyName);
      errDoc.addPage(
        pw.Page(
          pageFormat: format,
          margin: const pw.EdgeInsets.all(24),
          theme: pw.ThemeData.withFont(base: fontReg, bold: fontBold),
          build: (_) => pw.Center(
            child: pw.Column(
              mainAxisSize: pw.MainAxisSize.min,
              children: [
                pw.Text(
                  options.isArabic
                      ? ar('تعذر إنشاء الفاتورة للطباعة')
                      : 'Failed to generate invoice for printing',
                  style: pw.TextStyle(
                    fontSize: 14,
                    fontWeight: pw.FontWeight.bold,
                    color: gold,
                  ),
                  textDirection: pw.TextDirection.ltr,
                ),
                pw.SizedBox(height: 10),
                pw.Text(
                  e.toString(),
                  style: pw.TextStyle(
                    fontSize: 8,
                    color: PdfColor.fromInt(0xFF555555),
                  ),
                  textDirection: pw.TextDirection.ltr,
                  textAlign: pw.TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
      return errDoc.save();
    }
  }
}
