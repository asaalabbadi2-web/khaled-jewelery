import 'dart:typed_data';
import '../widgets/invoice_attribution_sheet.dart';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:pdf/pdf.dart';

import '../api_service.dart';
import '../pdf/voucher_pdf_builder.dart';
import '../providers/settings_provider.dart';
import '../theme/app_theme.dart' as theme;
import '../widgets/app_feedback.dart';
import '../utils/currency_utils.dart';
import '../widgets/voucher_actions.dart';
import '../utils/invoice_type_label.dart';

Future<bool?> showVoucherDetailsSheet(
  BuildContext context, {
  required int voucherId,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (sheetContext) {
      return FractionallySizedBox(
        heightFactor: 0.94,
        child: ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: VoucherDetailsScreen(voucherId: voucherId, asSheet: true),
        ),
      );
    },
  );
}

class VoucherDetailsScreen extends StatefulWidget {
  final int voucherId;
  final bool asSheet;

  const VoucherDetailsScreen({
    super.key,
    required this.voucherId,
    this.asSheet = false,
  });

  @override
  State<VoucherDetailsScreen> createState() => _VoucherDetailsScreenState();
}

class _VoucherDetailsScreenState extends State<VoucherDetailsScreen> {
  // ADR-049: every color from the theme, so the screen reads in dark mode too.
  ColorScheme get _cs => Theme.of(context).colorScheme;
  theme.AppSemanticColors get _tone => theme.AppSemanticColors.of(context);

  final ApiService _apiService = ApiService();

  Map<String, dynamic>? _voucher;
  bool _isLoading = true;
  String? _error;

  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'ar');
  final NumberFormat _weightFormat = NumberFormat('#,##0.000', 'ar');

  @override
  void initState() {
    super.initState();
    _loadVoucher();
  }

  // What this voucher's cash and gold pay -- shown in the voucher itself
  // («الفواتير التي يسددها السند»), not behind an icon (2 Oct 2026).
  Map<String, dynamic>? _cashAttribution;
  Map<String, dynamic>? _goldAttribution;

  Future<void> _loadAttributions(Map<String, dynamic> voucher) async {
    if (voucher['supplier_id'] is! int) return;
    Map<String, dynamic>? cash;
    Map<String, dynamic>? gold;
    try {
      if (_hasCashDebit(voucher)) {
        cash = await _apiService.getVoucherCashAttribution(widget.voucherId);
      }
    } catch (_) {}
    try {
      if (_hasGoldLines(voucher)) {
        gold = await _apiService.getVoucherGoldAttribution(widget.voucherId);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _cashAttribution = cash;
      _goldAttribution = gold;
    });
  }

  String _invoiceKnownAs(Map row) =>
      '${row['invoice_type'] == null ? 'فاتورة' : invoiceTypeLabel(row)} #${row['invoice_type_id'] ?? row['invoice_id']}';

  Future<void> _loadVoucher() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final voucher = await _apiService.getVoucher(widget.voucherId);
      setState(() {
        _voucher = voucher;
        _isLoading = false;
      });
      await _loadAttributions(voucher);
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteVoucher() async {
    final voucher = _voucher ?? {'id': widget.voucherId};
    if (!await confirmDeleteVoucher(context, voucher) || !mounted) return;
    try {
      await _apiService.deleteVoucher(widget.voucherId);
      if (!mounted) return;
      _showSnack('تم حذف السند');
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'لم يُحذف السند');
    }
  }

  Future<void> _cancelVoucher() async {
    final voucher = _voucher ?? {'id': widget.voucherId};
    final reason = await confirmCancelVoucher(context, voucher);
    if (reason == null || !mounted) return;
    try {
      await _apiService.cancelVoucher(widget.voucherId, reason);
      if (!mounted) return;
      _showSnack('تم إلغاء السند');
      _loadVoucher();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'لم يُلغَ السند');
    }
  }

  Future<void> _approveVoucher() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اعتماد السند'),
        content: const Text(
          'هل تريد اعتماد (ترحيل) هذا السند الآن؟ سيتم إنشاء قيد محاسبي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: _cs.primary,
            ),
            child: const Text('اعتماد'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _apiService.approveVoucher(widget.voucherId);
      if (!mounted) return;
      _showSnack('تم اعتماد السند');
      _loadVoucher();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'لم يُعتمد السند');
    }
  }

  Future<Uint8List> _buildVoucherPdfBytesWithSp(
    PdfPageFormat format,
    SettingsProvider? sp,
  ) async {
    final voucher = _voucher;
    if (voucher == null) return Uint8List(0);
    if (sp != null) {
      await sp.ensureLoadedForPrint();
    }
    final prefs = await SharedPreferences.getInstance();
    final bw = !(prefs.getBool('print_in_color') ?? true);
    return VoucherPdfBuilder.buildBytes(
      voucher: voucher,
      format: format,
      options: VoucherPdfOptions(
        isArabic: true,
        includeAccountLines: false,
        blackAndWhite: bw,
      ),
      settings: sp,
    );
  }

  Future<({String paperSize, String orientation})> _loadPrintPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final storedPaper = prefs.getString('printer_paper_size_v1') ?? 'A4';
    final normalizedPaper = storedPaper.contains('A5') ? 'A5' : 'A4';
    return (paperSize: normalizedPaper, orientation: 'portrait');
  }

  String _voucherPdfFilename() {
    final v = _voucher;
    final id = (v?['id'] ?? '').toString();
    final number = (v?['voucher_number'] ?? '').toString();
    final base = number.trim().isNotEmpty
        ? number.trim()
        : (id.isNotEmpty ? 'voucher_$id' : 'voucher');
    return '$base.pdf';
  }

  Future<void> _printVoucher() async {
    if (_voucher == null) return;
    SettingsProvider? sp;
    try {
      sp = context.read<SettingsProvider>();
    } catch (_) {}
    if (widget.asSheet && mounted) Navigator.of(context).pop();
    try {
      await Printing.layoutPdf(
        name: _voucherPdfFilename(),
        onLayout: (format) => _buildVoucherPdfBytesWithSp(format, sp),
      );
    } catch (_) {}
  }

  Future<void> _downloadVoucherPdf() async {
    if (_voucher == null) return;
    SettingsProvider? sp;
    try {
      sp = context.read<SettingsProvider>();
    } catch (_) {}
    if (widget.asSheet && mounted) Navigator.of(context).pop();
    try {
      final prefs = await _loadPrintPrefs();
      final format = VoucherPdfBuilder.pageFormatFromSettings(
        paperSize: prefs.paperSize,
        orientation: prefs.orientation,
      );
      final bytes = await _buildVoucherPdfBytesWithSp(format, sp);
      await Printing.sharePdf(bytes: bytes, filename: _voucherPdfFilename());
    } catch (_) {}
  }

  Future<void> _shareVoucherPdf() async {
    if (_voucher == null) return;
    SettingsProvider? sp;
    try {
      sp = context.read<SettingsProvider>();
    } catch (_) {}
    if (widget.asSheet && mounted) Navigator.of(context).pop();
    try {
      final prefs = await _loadPrintPrefs();
      final format = VoucherPdfBuilder.pageFormatFromSettings(
        paperSize: prefs.paperSize,
        orientation: prefs.orientation,
      );
      final bytes = await _buildVoucherPdfBytesWithSp(format, sp);
      await Printing.sharePdf(bytes: bytes, filename: _voucherPdfFilename());
    } catch (_) {}
  }

  bool _hasGoldLines(Map<String, dynamic> voucher) {
    final lines = voucher['account_lines'];
    if (lines is! List) return false;
    return lines.any((l) => (l is Map) && l['amount_type'] == 'gold');
  }

  /// Correcting a classification after approval. A payment declared a general
  /// supplier settlement records no attribution — correct by design, but it left
  /// the invoice with no way back, its gold side unsettled even when the amount
  /// matched exactly. The employee states the invoice here; nothing is inferred.
  Future<void> _openGoldAttributionSheet() async {
    final voucher = _voucher;
    if (voucher == null) return;
    final supplierId = voucher['supplier_id'];
    if (supplierId is! int) {
      AppFeedback.info(context, 'النسب متاح لسندات الموردين فقط');
      return;
    }

    Map<String, dynamic>? current;
    List<Map<String, dynamic>> candidates = const [];
    try {
      current = await _apiService.getVoucherGoldAttribution(widget.voucherId);
      candidates = await _apiService.getSupplierOpenGoldObligations(supplierId);
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'تعذّر جلب بيانات النسب');
      return;
    }
    if (!mounted) return;

    final mainKarat = context.read<SettingsProvider>().mainKarat.toDouble();
    final karat = _firstGoldKarat(voucher);
    final unattributed =
        (current['unattributed_main_karat'] as num?)?.toDouble() ?? 0.0;
    final existing =
        (current['attributions'] as List?)?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => InvoiceAttributionSheet(
        title: 'نسب ذهب السند إلى فاتورة',
        unit: 'جم',
        unattributed: unattributed,
        emptyText: 'لا توجد فواتير لهذا المورد عليها التزام ذهب مفتوح',
        existing: existing
            .map((row) => AttributionExisting(
                  id: (row['id'] as num).toInt(),
                  label: '${_invoiceKnownAs(row)} · '
                      '${(row['weight'] as num?) == null ? '?' : formatGrams(row['weight'] as num, decimals: 2)} جم عيار ${row['karat']}',
                  amount: (row['weight_main_karat'] as num?)?.toDouble() ?? 0.0,
                  removable: true,
                ))
            .toList(),
        candidates: candidates
            .map((row) => AttributionCandidate(
                  invoiceId: (row['invoice_id'] as num).toInt(),
                  label: '${row['invoice_type'] == null ? 'فاتورة' : invoiceTypeLabel(row)} #${row['invoice_type_id'] ?? row['invoice_id']}',
                  date: DateTime.tryParse('${row['date'] ?? ''}'),
                  open: (row['open_main_karat'] as num?)?.toDouble() ?? 0.0,
                  details: [
                    for (final k in (row['karats'] as List? ?? const []))
                      'عيار ${(k as Map)['karat']}: متبقٍ '
                          '${formatGrams((k['attributed_remaining_main_karat'] as num?) ?? 0, decimals: 2)} جم '
                          '(بالعيار ${mainKarat.toInt()})',
                  ],
                ))
            .toList(),
        onAttribute: (invoiceId, amountMainKarat) async {
          // The sheet works in main-karat grams; the voucher's gold is in its
          // own karat. Sending the main-karat figure as the karat's weight
          // under-attributed every non-main karat (2 Oct 2026: 24.2 g of 18k
          // went as 20.74 g of 18k).
          final weight = karatWeightFromMain(amountMainKarat, mainKarat, karat);
          await _apiService.attributeVoucherGold(
            widget.voucherId,
            invoiceId: invoiceId,
            karat: karat,
            weight: weight,
          );
          if (!sheetContext.mounted) return;
          Navigator.of(sheetContext).pop();
          await _loadVoucher();
          await _offerOtherSide(done: 'gold', invoiceId: invoiceId);
        },
        onRemove: (row) async {
          await _apiService.removeVoucherGoldAttribution(widget.voucherId, row.id);
          if (!sheetContext.mounted) return;
          Navigator.of(sheetContext).pop();
          await _loadVoucher();
        },
      ),
    );
  }

  /// The owner (2 Oct 2026): a voucher attributed to an invoice, carrying gold
  /// and cash, pays that invoice with both. Once one side is attributed here,
  /// offer the other to the same invoice -- capped by what each side allows.
  Future<void> _offerOtherSide({required String done, required int invoiceId}) async {
    final voucher = _voucher;
    final supplierId = voucher?['supplier_id'];
    if (voucher == null || supplierId is! int) return;
    final otherIsCash = done == 'gold';
    if (otherIsCash ? !_hasCashDebit(voucher) : !_hasGoldLines(voucher)) return;
    try {
      double left;
      double open = 0;
      String label = '';
      if (otherIsCash) {
        final mine = await _apiService.getVoucherCashAttribution(widget.voucherId);
        left = (mine['unattributed'] as num?)?.toDouble() ?? 0;
        for (final r in await _apiService.getSupplierOpenCashObligations(supplierId)) {
          if ((r['invoice_id'] as num).toInt() == invoiceId) {
            open = (r['open_cash'] as num?)?.toDouble() ?? 0;
            label = _invoiceKnownAs(r);
          }
        }
      } else {
        final mine = await _apiService.getVoucherGoldAttribution(widget.voucherId);
        left = (mine['unattributed_main_karat'] as num?)?.toDouble() ?? 0;
        for (final r in await _apiService.getSupplierOpenGoldObligations(supplierId)) {
          if ((r['invoice_id'] as num).toInt() == invoiceId) {
            open = (r['open_main_karat'] as num?)?.toDouble() ?? 0;
            label = _invoiceKnownAs(r);
          }
        }
      }
      final amount = left < open ? left : open;
      if (amount <= 0.005 || !mounted) return;
      final unit = otherIsCash ? 'ر.س' : 'جم';
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(otherIsCash ? 'ونقد السند؟' : 'وذهب السند؟'),
          content: Text(
            'السند يحمل ${otherIsCash ? 'نقدًا' : 'ذهبًا'} غير منسوب. '
            'انسب ${formatAmount(amount)} $unit منه إلى $label أيضًا؟',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(c).pop(false), child: const Text('لا')),
            FilledButton(onPressed: () => Navigator.of(c).pop(true), child: const Text('انسب')),
          ],
        ),
      );
      if (ok != true) return;
      if (otherIsCash) {
        await _apiService.attributeVoucherCash(widget.voucherId, invoiceId: invoiceId, amount: amount);
      } else {
        final mainKarat = context.read<SettingsProvider>().mainKarat.toDouble();
        final karat = _firstGoldKarat(voucher);
        await _apiService.attributeVoucherGold(widget.voucherId,
            invoiceId: invoiceId, karat: karat, weight: karatWeightFromMain(amount, mainKarat, karat));
      }
      await _loadVoucher();
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'تعذّر نسب الجانب الآخر');
    }
  }

  bool _hasCashDebit(Map<String, dynamic> voucher) {
    final lines = voucher['account_lines'];
    if (lines is! List) return false;
    return lines.any((l) =>
        (l is Map) && l['amount_type'] == 'cash' && l['line_type'] == 'debit');
  }

  /// The gold sheet's mirror for cash (2 Oct 2026): a supplier payment recorded
  /// as a general settlement can be attributed to the invoice it paid. The books
  /// do not move; the invoice records which payment settled it.
  Future<void> _openCashAttributionSheet() async {
    final voucher = _voucher;
    if (voucher == null) return;
    final supplierId = voucher['supplier_id'];
    if (supplierId is! int) {
      AppFeedback.info(context, 'النسب متاح لسندات الموردين فقط');
      return;
    }

    Map<String, dynamic>? current;
    List<Map<String, dynamic>> candidates = const [];
    try {
      current = await _apiService.getVoucherCashAttribution(widget.voucherId);
      candidates = await _apiService.getSupplierOpenCashObligations(supplierId);
    } catch (e) {
      if (!mounted) return;
      AppFeedback.error(context, e, title: 'تعذّر جلب بيانات النسب');
      return;
    }
    if (!mounted) return;

    final unattributed = (current['unattributed'] as num?)?.toDouble() ?? 0.0;
    final existing =
        (current['payments'] as List?)?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];
    String money(num? v) => formatAmount(v ?? 0);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => InvoiceAttributionSheet(
        title: 'نسب نقد السند إلى فاتورة',
        unit: 'ر.س',
        unattributed: unattributed,
        emptyText: 'لا توجد فواتير لهذا المورد عليها التزام نقدي مفتوح',
        existing: existing
            .map((row) => AttributionExisting(
                  id: (row['id'] as num).toInt(),
                  label: _invoiceKnownAs(row),
                  amount: (row['amount'] as num?)?.toDouble() ?? 0.0,
                  removable: row['removable'] == true,
                  lockedReason: 'دفعة السند لفاتورته — تُلغى بإلغاء السند',
                ))
            .toList(),
        candidates: candidates
            .map((row) => AttributionCandidate(
                  invoiceId: (row['invoice_id'] as num).toInt(),
                  label: '${row['invoice_type'] == null ? 'فاتورة' : invoiceTypeLabel(row)} #${row['invoice_type_id'] ?? row['invoice_id']}',
                  date: DateTime.tryParse('${row['date'] ?? ''}'),
                  open: (row['open_cash'] as num?)?.toDouble() ?? 0.0,
                  details: [
                    'المطلوب نقدًا ${money(row['cash_obligation'] as num?)} · '
                        'المدفوع ${money(row['paid'] as num?)}',
                  ],
                ))
            .toList(),
        onAttribute: (invoiceId, amount) async {
          await _apiService.attributeVoucherCash(
            widget.voucherId,
            invoiceId: invoiceId,
            amount: amount,
          );
          if (!sheetContext.mounted) return;
          Navigator.of(sheetContext).pop();
          await _loadVoucher();
          await _offerOtherSide(done: 'cash', invoiceId: invoiceId);
        },
        onRemove: (row) async {
          await _apiService.removeVoucherCashAttribution(widget.voucherId, row.id);
          if (!sheetContext.mounted) return;
          Navigator.of(sheetContext).pop();
          await _loadVoucher();
        },
      ),
    );
  }

  /// The real karat on the voucher's gold lines — never a converted equivalent.
  double _firstGoldKarat(Map<String, dynamic> voucher) {
    final lines = voucher['account_lines'];
    if (lines is List) {
      for (final l in lines) {
        if (l is Map && l['amount_type'] == 'gold' && l['karat'] != null) {
          return (l['karat'] as num).toDouble();
        }
      }
    }
    return 21.0;
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    if (_isLoading) {
      return widget.asSheet
          ? Material(
              color: _cs.surfaceContainerLowest,
              child: Center(child: CircularProgressIndicator()),
            )
          : Scaffold(
              appBar: AppBar(title: const Text('تفاصيل السند')),
              body: const Center(child: CircularProgressIndicator()),
            );
    }

    if (_error != null || _voucher == null) {
      final errorBody = Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: _cs.error),
            const SizedBox(height: 16),
            Text('خطأ: $_error'),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadVoucher,
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );

      return widget.asSheet
          ? Material(color: _cs.surfaceContainerLowest, child: errorBody)
          : Scaffold(
              appBar: AppBar(title: const Text('تفاصيل السند')),
              body: errorBody,
            );
    }

    final voucher = _voucher!;
    final voucherType = voucher['voucher_type'] ?? 'unknown';
    final status = voucher['status'] ?? 'active';
    final isCancelled = status == 'cancelled';
    final isActive = status == 'active';
    final double? amountCash = _toDouble(voucher['amount_cash']);
    final double? amountGold = _toDouble(voucher['amount_gold']);

    Color typeColor;
    IconData typeIcon;
    String typeText;

    switch (voucherType) {
      case 'receipt':
        typeColor = theme.AppSemanticColors.of(
          context,
        ).voucher(theme.VoucherKind.receipt).fg;
        typeIcon = Icons.south;
        typeText = 'سند قبض';
        break;
      case 'payment':
        typeColor = theme.AppSemanticColors.of(
          context,
        ).voucher(theme.VoucherKind.payment).fg;
        typeIcon = Icons.north;
        typeText = 'سند صرف';
        break;
      case 'adjustment':
        typeColor = _tone.warning.fg;
        typeIcon = Icons.balance;
        typeText = 'سند تسوية';
        break;
      default:
        typeColor = _cs.onSurfaceVariant;
        typeIcon = Icons.help;
        typeText = 'غير محدد';
    }

    final actions = [
      if (isActive) ...[
        IconButton(
          icon: const Icon(Icons.cancel),
          onPressed: _cancelVoucher,
          tooltip: 'إلغاء السند',
        ),
        IconButton(
          icon: const Icon(Icons.delete),
          onPressed: _deleteVoucher,
          tooltip: 'حذف السند',
        ),
      ],
      if (!isCancelled && (voucher['status'] ?? '') != 'approved')
        IconButton(
          icon: const Icon(Icons.check_circle_outline),
          onPressed: () async => await _approveVoucher(),
          tooltip: 'اعتماد/ترحيل السند',
        ),
      IconButton(
        icon: const Icon(Icons.download),
        onPressed: _downloadVoucherPdf,
        tooltip: 'تحميل PDF',
      ),
      IconButton(
        icon: const Icon(Icons.share),
        onPressed: _shareVoucherPdf,
        tooltip: 'مشاركة',
      ),
      IconButton(
        icon: const Icon(Icons.print),
        onPressed: _printVoucher,
        tooltip: 'طباعة',
      ),
    ];

    final String voucherNumber = (voucher['voucher_number'] ?? '').toString();
    final String statusText = _getStatusName(status.toString());
    final Color statusColor = _getStatusColor(status.toString());
    final String dateText = _formatDateOnly(voucher['date']);

    final String? cashText = (amountCash != null && amountCash > 0)
        ? '${_currencyFormat.format(amountCash)} ${context.read<SettingsProvider>().currencySymbolText}'
        : null;
    final String? goldText = (amountGold != null && amountGold > 0)
        ? '${_weightFormat.format(amountGold)} غ'
        : null;
    final String? equivalentGoldText = _formatEquivalentGold(voucher);
    final List<String> goldBreakdownLines = _extractGoldBreakdownLines(voucher);

    final body = RefreshIndicator(
      onRefresh: _loadVoucher,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildSectionCard(
              title: 'ملخص السند',
              icon: Icons.receipt_long_outlined,
              accentColor: typeColor,
              child: Column(
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          color: typeColor.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(typeIcon, color: typeColor, size: 26),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              voucherNumber,
                              style: Theme.of(context).textTheme.headlineMedium
                                  ?.copyWith(
                                    fontWeight: FontWeight.w800,
                                    decoration: isCancelled
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              typeText,
                              style: TextStyle(
                                color: typeColor,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: statusColor.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: statusColor.withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          statusText,
                          style: TextStyle(
                            color: statusColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _buildInfoRow('التاريخ', dateText, Icons.calendar_today),
                  if (isCancelled) ...[
                    const SizedBox(height: 8),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: _tone.blocked.container,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: _tone.blocked.fg.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'السند ملغى',
                            style: TextStyle(
                              color: _tone.blocked.fg,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (voucher['cancellation_reason'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'السبب: ${voucher['cancellation_reason']}',
                                style: TextStyle(color: _cs.onSurface),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),

            _buildSectionCard(
              title: 'المبلغ والوزن',
              icon: Icons.account_balance_wallet_outlined,
              accentColor: _cs.primary,
              child: Column(
                children: [
                  if (cashText != null)
                    _buildAmountRow(
                      'المبلغ النقدي',
                      cashText,
                      Icons.payments_outlined,
                      _tone.ready.fg,
                    ),
                  if (goldText != null)
                    _buildAmountRow(
                      'وزن الذهب',
                      goldText,
                      Icons.scale_outlined,
                      _tone.gold.fg,
                    ),
                  if (equivalentGoldText != null)
                    _buildAmountRow(
                      'الوزن المكافئ',
                      equivalentGoldText,
                      Icons.auto_awesome,
                      _tone.gold.fg,
                    ),
                  if (goldBreakdownLines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _tone.warning.container,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: _tone.warning.fg.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'تفصيل العيارات',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: _cs.onSurface,
                              ),
                            ),
                            const SizedBox(height: 6),
                            ...goldBreakdownLines.map(
                              (line) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  line,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (cashText == null && goldText == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'لا توجد قيم مالية أو وزنية مسجلة.',
                        style: TextStyle(color: _cs.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // ── الطرف ──────────────────────────────────────────────────
            () {
              final partyType  = voucher['party_type']?.toString();
              final partyName  = voucher['party_name']?.toString();
              final customerObj = voucher['customer'] as Map?;
              final supplierObj = voucher['supplier'] as Map?;
              final employeeObj = voucher['employee'] as Map?;
              final receiver   = voucher['receiver_name']?.toString();

              // اسم الطرف الفعلي بأولوية: كائن > party_name > —
              final resolvedName =
                  customerObj?['name']?.toString() ??
                  supplierObj?['name']?.toString() ??
                  employeeObj?['name']?.toString() ??
                  employeeObj?['full_name']?.toString() ??
                  (partyName?.isNotEmpty == true ? partyName : null);

              if (partyType == null && resolvedName == null && receiver == null) {
                return const SizedBox.shrink();
              }
              return Column(
                children: [
                  _buildSectionCard(
                    title: 'الطرف',
                    icon: Icons.groups_outlined,
                    accentColor: _tone.sectionSlate.fg,
                    child: Column(
                      children: [
                        if (partyType != null)
                          _buildInfoRow(
                            'نوع الطرف',
                            _getPartyTypeName(partyType),
                            Icons.category_outlined,
                          ),
                        if (resolvedName != null)
                          _buildInfoRow(
                            partyType == 'employee'
                                ? 'الموظف'
                                : partyType == 'supplier'
                                    ? 'المورد'
                                    : 'العميل',
                            resolvedName,
                            partyType == 'employee'
                                ? Icons.badge_outlined
                                : partyType == 'supplier'
                                    ? Icons.store_outlined
                                    : Icons.person_outline,
                          ),
                        if (receiver != null && receiver.isNotEmpty &&
                            receiver != resolvedName)
                          _buildInfoRow(
                            'المستلم',
                            receiver,
                            Icons.handshake_outlined,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              );
            }(),

            if (voucher['description'] != null &&
                voucher['description'].toString().isNotEmpty)
              _buildSectionCard(
                title: 'البيان',
                icon: Icons.description_outlined,
                accentColor: _tone.sectionIndigo.fg,
                child: Text(
                  voucher['description'],
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: _cs.onSurface,
                    height: 1.5,
                  ),
                ),
              ),
            const SizedBox(height: 12),

            if (voucher['reference_type'] != null &&
                voucher['reference_type'] != 'manual')
              _buildSectionCard(
                title: 'المرجع',
                icon: Icons.link_outlined,
                accentColor: _tone.sectionTeal.fg,
                child: Column(
                  children: [
                    _buildInfoRow(
                      'نوع المرجع',
                      _getReferenceTypeName(voucher['reference_type']),
                      Icons.link,
                    ),
                    if (voucher['reference_number'] != null &&
                        voucher['reference_number'].toString().isNotEmpty)
                      _buildInfoRow(
                        'رقم المرجع',
                        voucher['reference_number'].toString(),
                        Icons.tag,
                      )
                    else if (voucher['reference_id'] != null)
                      _buildInfoRow(
                        'رقم المرجع',
                        '#${voucher['reference_id']}',
                        Icons.tag,
                      ),
                  ],
                ),
              ),
            const SizedBox(height: 12),

            if (voucher['supplier_id'] is int &&
                (_cashAttribution != null || _goldAttribution != null)) ...[
              _buildSectionCard(
                title: 'الفواتير التي يسددها السند',
                icon: Icons.receipt_long_outlined,
                accentColor: _tone.sectionOrange.fg,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_cashAttribution != null)
                      AttributionSummaryCard(
                        unit: 'ر.س',
                        kindLabel: 'النقد',
                        capacity: (_cashAttribution!['cash_capacity'] as num?)?.toDouble() ?? 0,
                        attributed: (_cashAttribution!['attributed'] as num?)?.toDouble() ?? 0,
                        approved: (voucher['status'] ?? '') == 'approved',
                        rows: [
                          for (final r in (_cashAttribution!['payments'] as List? ?? const []))
                            AttributionSummaryRow(
                              label: _invoiceKnownAs(r as Map),
                              amount: (r['amount'] as num?)?.toDouble() ?? 0,
                              date: DateTime.tryParse('${r['invoice_date'] ?? ''}'),
                            ),
                        ],
                        onOpen: _openCashAttributionSheet,
                      ),
                    if (_cashAttribution != null && _goldAttribution != null)
                      const Divider(height: 24),
                    if (_goldAttribution != null)
                      AttributionSummaryCard(
                        unit: 'جم',
                        kindLabel: 'الذهب (بالعيار الرئيسي)',
                        capacity: (_goldAttribution!['gold_capacity_main_karat'] as num?)?.toDouble() ?? 0,
                        attributed: (_goldAttribution!['attributed_main_karat'] as num?)?.toDouble() ?? 0,
                        approved: (voucher['status'] ?? '') == 'approved',
                        rows: [
                          for (final r in (_goldAttribution!['attributions'] as List? ?? const []))
                            AttributionSummaryRow(
                              label: '${_invoiceKnownAs(r as Map)} · '
                                  '${(r['weight'] as num?) == null ? '?' : formatGrams(r['weight'] as num, decimals: 2)} جم عيار ${r['karat']}',
                              amount: (r['weight_main_karat'] as num?)?.toDouble() ?? 0,
                              date: DateTime.tryParse('${r['invoice_date'] ?? ''}'),
                            ),
                        ],
                        onOpen: _openGoldAttributionSheet,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // The note the employee wrote; a voucher written for chosen
            // invoices carries its splits beside it in `notes` (VOUCHER-ATTR-1).
            if ('${voucher['note_text'] ?? voucher['notes'] ?? ''}'.isNotEmpty)
              _buildSectionCard(
                title: 'ملاحظات',
                icon: Icons.sticky_note_2_outlined,
                accentColor: _tone.gold.fg,
                child: Text(
                  '${voucher['note_text'] ?? voucher['notes']}',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: _cs.onSurface,
                    height: 1.45,
                  ),
                ),
              ),
            const SizedBox(height: 12),

            // ── سطور الحسابات (القيد المحاسبي) ─────────────────────────
            () {
              final lines = (voucher['account_lines'] as List?) ?? [];
              if (lines.isEmpty) return const SizedBox.shrink();
              final currency = context.read<SettingsProvider>().currencySymbolText;
              return Column(
                children: [
                  _buildSectionCard(
                    title: 'القيد المحاسبي',
                    icon: Icons.account_tree_outlined,
                    accentColor: _tone.sectionIndigo.fg,
                    child: Column(
                      children: [
                        // رأس الجدول
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: _cs.surfaceContainerHigh,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                flex: 5,
                                child: Text(
                                  'الحساب',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              SizedBox(
                                width: 6,
                                child: Text(
                                  '',
                                  style: Theme.of(
                                    context,
                                  ).textTheme.labelSmall?.copyWith(),
                                ),
                              ),
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'مدين',
                                  textAlign: TextAlign.end,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: _tone.debit.fg,
                                      ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              Expanded(
                                flex: 3,
                                child: Text(
                                  'دائن',
                                  textAlign: TextAlign.end,
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                        color: _tone.credit.fg,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        ...lines.map<Widget>((l) {
                          if (l is! Map) return const SizedBox.shrink();
                          final accObj  = l['account'] as Map?;
                          final accNum  = accObj?['account_number']?.toString() ?? '';
                          final accName = accObj?['name']?.toString() ?? '—';
                          final lineType = l['line_type']?.toString() ?? '';
                          final isDebit  = lineType == 'debit';
                          final amt      = (l['amount'] as num?)?.toDouble() ?? 0.0;
                          final amtType  = l['amount_type']?.toString() ?? 'cash';
                          final unit     = amtType == 'gold' ? 'جم' : currency;
                          final amtStr   = '${formatAmount(amt, decimals: amtType == 'gold' ? 3 : 2)} $unit';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                            decoration: BoxDecoration(
                              color: isDebit
                                  ? _tone.debit.container
                                  : _tone.credit.container,
                              borderRadius: BorderRadius.circular(7),
                              border: Border(
                                right: BorderSide(
                                  color: isDebit ? _tone.debit.fg.withValues(alpha: 0.5) : _tone.credit.fg.withValues(alpha: 0.5),
                                  width: 3,
                                ),
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  flex: 5,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        accName,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              fontWeight: FontWeight.w700,
                                            ),
                                      ),
                                      if (accNum.isNotEmpty)
                                        Text(
                                          accNum,
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: _cs.onSurfaceVariant,
                                              ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    isDebit ? amtStr : '',
                                    textAlign: TextAlign.end,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: _tone.debit.fg,
                                        ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    !isDebit ? amtStr : '',
                                    textAlign: TextAlign.end,
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(
                                          fontWeight: FontWeight.w700,
                                          color: _tone.credit.fg,
                                        ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              );
            }(),

            _buildSectionCard(
              title: 'معلومات إضافية',
              icon: Icons.info_outline,
              accentColor: _tone.sectionSlate.fg,
              child: Column(
                children: [
                  _buildInfoRow(
                    'تاريخ الإنشاء',
                    _formatDateTime(voucher['created_at']),
                    Icons.access_time,
                  ),
                  if (voucher['updated_at'] != null)
                    _buildInfoRow(
                      'آخر تحديث',
                      _formatDateTime(voucher['updated_at']),
                      Icons.update,
                    ),
                  if (voucher['created_by'] != null)
                    _buildInfoRow(
                      'المستخدم',
                      voucher['created_by'],
                      Icons.person,
                    ),
                  if (voucher['approved_by'] != null)
                    _buildInfoRow(
                      'اعتمد بواسطة',
                      voucher['approved_by'],
                      Icons.verified_outlined,
                    ),
                  if (voucher['approved_at'] != null)
                    _buildInfoRow(
                      'تاريخ الاعتماد',
                      _formatDateTime(voucher['approved_at']),
                      Icons.check_circle_outline,
                    ),
                ],
              ),
            ),

            if (voucher['audit_log'] != null &&
                voucher['audit_log'] is List &&
                voucher['audit_log'].isNotEmpty) ...[
              const SizedBox(height: 12),
              _buildSectionCard(
                title: 'سجل التعديلات',
                icon: Icons.history,
                accentColor: _tone.sectionAmber.fg,
                child: Column(
                  children: [
                    ...voucher['audit_log'].map<Widget>(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _tone.sectionAmber.container,
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.person,
                                size: 18,
                                color: _cs.onSurfaceVariant,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      (entry['user'] ?? '---').toString(),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _formatDateTime(entry['timestamp']),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: _cs.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                              if (entry['action'] != null)
                                Text(
                                  '(${entry['action']})',
                                  style: Theme.of(context).textTheme.bodySmall
                                      ?.copyWith(color: _cs.onSurfaceVariant),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );

    if (widget.asSheet) {
      return Material(
        color: _cs.surfaceContainerLowest,
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(
                color: typeColor.withValues(alpha: 0.08),
                border: Border(
                  bottom: BorderSide(color: typeColor.withValues(alpha: 0.18)),
                ),
              ),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 44,
                      height: 5,
                      decoration: BoxDecoration(
                        color: _cs.shadow.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(100),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.of(context).pop(),
                        tooltip: 'إغلاق',
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              typeText,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w800),
                            ),
                            Text(
                              voucherNumber,
                              style: TextStyle(
                                color: _cs.scrim.withValues(alpha: 0.65),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...actions,
                    ],
                  ),
                ],
              ),
            ),
            Expanded(child: body),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(typeText),
        backgroundColor: typeColor,
        actions: actions,
      ),
      body: body,
    );
  }

  void _showSnack(String message, {bool error = false}) {
    if (error) {
      AppFeedback.error(context, message);
    } else {
      AppFeedback.success(context, message);
    }
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  String _formatDateOnly(dynamic value) {
    if (value == null) return 'غير محدد';
    final raw = value.toString();
    if (raw.isEmpty) return 'غير محدد';
    try {
      final dt = DateTime.parse(raw);
      // Use Western digits so date stays stable alongside mixed RTL/LTR text.
      return DateFormat('yyyy/MM/dd', 'en').format(dt);
    } catch (_) {
      return raw;
    }
  }

  String? _formatEquivalentGold(Map<String, dynamic> voucher) {
    final double? amount = _toDouble(voucher['amount_gold_main_karat']);
    if (amount == null || amount == 0) return null;
    final int mainKarat = (_toDouble(voucher['main_karat']) ?? 21).round();
    return 'مكافئ عيار $mainKarat: ${_weightFormat.format(amount)} غ';
  }

  List<String> _extractGoldBreakdownLines(Map<String, dynamic> voucher) {
    final raw = voucher['gold_breakdown'];
    if (raw is List && raw.isNotEmpty) {
      return raw.whereType<Map>().map((entry) {
        final double? weightValue = _toDouble(entry['weight']);
        final String weight = _weightFormat.format(weightValue ?? 0);
        final karat = _toDouble(entry['karat'])?.round() ?? entry['karat'];
        return '• عيار $karat: $weight غ';
      }).toList();
    }

    final double? amountGold = _toDouble(voucher['amount_gold']);
    if (amountGold == null || amountGold == 0) return const [];
    final karat = voucher['gold_karat'];
    if (karat == null || karat.toString().isEmpty || karat == 'متعدد') {
      return ['• إجمالي الذهب: ${_weightFormat.format(amountGold)} غ'];
    }
    return [
      '• عيار ${_toDouble(karat)?.round() ?? karat}: ${_weightFormat.format(amountGold)} غ',
    ];
  }

  String _getStatusName(String status) {
    switch (status) {
      case 'approved':
        return 'مُعتمد';
      case 'cancelled':
        return 'ملغى';
      case 'voided':
        return 'مُبطل';
      case 'active':
      default:
        return 'نشط';
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'approved':
        return _tone.ready.fg;
      case 'cancelled':
      case 'voided':
        return _tone.blocked.fg;
      case 'active':
      default:
        return _cs.onSurfaceVariant;
    }
  }

  Widget _buildSectionCard({
    required String title,
    required IconData icon,
    required Color accentColor,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: _cs.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: accentColor.withValues(alpha: 0.18)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: accentColor),
                const SizedBox(width: 6),
                Text(
                  title,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: accentColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            child,
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: _cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _cs.onSurfaceVariant),
                ),
                Text(
                  value,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w500,
                    color: _cs.onSurface,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountRow(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: _cs.onSurfaceVariant),
                ),
                Text(
                  value,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getPartyTypeName(String? type) {
    switch (type) {
      case 'customer':
        return 'عميل';
      case 'supplier':
        return 'مورد';
      case 'employee':
        return 'موظف';
      case 'other':
        return 'آخر';
      default:
        return 'غير محدد';
    }
  }

  String _getReferenceTypeName(String? type) {
    switch (type) {
      case 'invoice':
        return 'فاتورة';
      case 'journal_entry':
        return 'قيد محاسبي';
      case 'manual':
        return 'يدوي';
      default:
        return 'غير محدد';
    }
  }

  String _formatDateTime(String? dateTime) {
    if (dateTime == null) return 'غير محدد';
    try {
      final dt = DateTime.parse(dateTime);
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (e) {
      return dateTime;
    }
  }
}
