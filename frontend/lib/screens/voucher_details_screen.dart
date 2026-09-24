import 'dart:typed_data';

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
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteVoucher() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text(
          'هل أنت متأكد من حذف هذا السند؟\nلا يمكن التراجع عن هذا الإجراء.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: theme.AppColors.error),
            child: const Text('حذف'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _apiService.deleteVoucher(widget.voucherId);
        if (!mounted) return;
        _showSnack('تم حذف السند بنجاح');
        Navigator.pop(context, true);
      } catch (e) {
        if (!mounted) return;
        _showSnack('خطأ في الحذف: $e', error: true);
      }
    }
  }

  Future<void> _cancelVoucher() async {
    String? reason;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء السند'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('الرجاء إدخال سبب الإلغاء:'),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                hintText: 'سبب الإلغاء',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) => reason = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: theme.AppColors.error),
            child: const Text('إلغاء السند'),
          ),
        ],
      ),
    );

    if (confirm == true && reason != null && reason!.isNotEmpty) {
      try {
        await _apiService.cancelVoucher(widget.voucherId, reason!);
        if (!mounted) return;
        _showSnack('تم إلغاء السند بنجاح');
        _loadVoucher();
      } catch (e) {
        if (!mounted) return;
        _showSnack('خطأ في الإلغاء: $e', error: true);
      }
    } else if (confirm == true) {
      _showSnack('يجب إدخال سبب الإلغاء', error: true);
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
              foregroundColor: theme.AppColors.primaryGold,
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
      _showSnack('خطأ في اعتماد السند: $e', error: true);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('النسب متاح لسندات الموردين فقط')),
      );
      return;
    }

    Map<String, dynamic>? current;
    List<Map<String, dynamic>> candidates = const [];
    try {
      current = await _apiService.getVoucherGoldAttribution(widget.voucherId);
      candidates = await _apiService.getSupplierOpenGoldObligations(supplierId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذّر جلب بيانات النسب: $e')),
      );
      return;
    }
    if (!mounted) return;

    final unattributed =
        (current['unattributed_main_karat'] as num?)?.toDouble() ?? 0.0;
    final existing =
        (current['attributions'] as List?)?.cast<Map<String, dynamic>>() ??
            const <Map<String, dynamic>>[];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'نسب ذهب السند إلى فاتورة',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              'غير المنسوب من هذا السند: ${unattributed.toStringAsFixed(2)} جم',
              style: const TextStyle(fontSize: 12, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            if (existing.isNotEmpty) ...[
              const Text('منسوب حاليًا', style: TextStyle(fontWeight: FontWeight.w600)),
              ...existing.map((row) => ListTile(
                    dense: true,
                    title: Text(
                      'فاتورة #${row['invoice_id']} · '
                      '${(row['weight'] as num?)?.toStringAsFixed(2) ?? '?'} جم '
                      'عيار ${row['karat']}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      tooltip: 'إلغاء هذا النسب',
                      onPressed: () async {
                        try {
                          await _apiService.removeVoucherGoldAttribution(
                            widget.voucherId,
                            (row['id'] as num).toInt(),
                          );
                          if (!sheetContext.mounted) return;
                          Navigator.of(sheetContext).pop();
                          await _loadVoucher();
                        } catch (e) {
                          if (!sheetContext.mounted) return;
                          ScaffoldMessenger.of(sheetContext).showSnackBar(
                            SnackBar(content: Text('فشل الإلغاء: $e')),
                          );
                        }
                      },
                    ),
                  )),
              const Divider(),
            ],
            if (unattributed <= 0.005)
              const Text(
                'لا يوجد ذهب غير منسوب في هذا السند',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              )
            else if (candidates.isEmpty)
              const Text(
                'لا توجد فواتير لهذا المورد عليها التزام ذهب مفتوح',
                style: TextStyle(fontSize: 12, color: Colors.redAccent),
              )
            else
              ...candidates.map((row) {
                final id = (row['invoice_id'] as num).toInt();
                final open = (row['open_main_karat'] as num?)?.toDouble() ?? 0.0;
                final amount = unattributed < open ? unattributed : open;
                return ListTile(
                  dense: true,
                  title: Text('فاتورة #$id · متبقٍ ${open.toStringAsFixed(2)} جم',
                      style: const TextStyle(fontSize: 13)),
                  trailing: TextButton(
                    child: Text('انسب ${amount.toStringAsFixed(2)} جم'),
                    onPressed: () async {
                      try {
                        await _apiService.attributeVoucherGold(
                          widget.voucherId,
                          invoiceId: id,
                          karat: _firstGoldKarat(voucher),
                          weight: amount,
                        );
                        if (!sheetContext.mounted) return;
                        Navigator.of(sheetContext).pop();
                        await _loadVoucher();
                      } catch (e) {
                        if (!sheetContext.mounted) return;
                        ScaffoldMessenger.of(sheetContext).showSnackBar(
                          SnackBar(content: Text('فشل النسب: $e')),
                        );
                      }
                    },
                  ),
                );
              }),
          ],
        ),
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
          ? const Material(
              color: Colors.white,
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
            Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
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
          ? Material(color: Colors.white, child: errorBody)
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
        typeColor = Colors.green;
        typeIcon = Icons.south;
        typeText = 'سند قبض';
        break;
      case 'payment':
        typeColor = Colors.red;
        typeIcon = Icons.north;
        typeText = 'سند صرف';
        break;
      case 'adjustment':
        typeColor = Colors.orange;
        typeIcon = Icons.balance;
        typeText = 'سند تسوية';
        break;
      default:
        typeColor = Colors.grey;
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
      if ((voucher['status'] ?? '') == 'approved' && _hasGoldLines(voucher))
        IconButton(
          icon: const Icon(Icons.link),
          onPressed: _openGoldAttributionSheet,
          tooltip: 'نسب ذهب السند إلى فاتورة',
        ),
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
                              style: TextStyle(
                                fontSize: 22,
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
                        color: Colors.red.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: Colors.red.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'السند ملغى',
                            style: TextStyle(
                              color: Colors.red,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          if (voucher['cancellation_reason'] != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                'السبب: ${voucher['cancellation_reason']}',
                                style: const TextStyle(color: Colors.black87),
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
              accentColor: theme.AppColors.primaryGold,
              child: Column(
                children: [
                  if (cashText != null)
                    _buildAmountRow(
                      'المبلغ النقدي',
                      cashText,
                      Icons.payments_outlined,
                      theme.AppColors.success,
                    ),
                  if (goldText != null)
                    _buildAmountRow(
                      'وزن الذهب',
                      goldText,
                      Icons.scale_outlined,
                      theme.AppColors.darkGold,
                    ),
                  if (equivalentGoldText != null)
                    _buildAmountRow(
                      'الوزن المكافئ',
                      equivalentGoldText,
                      Icons.auto_awesome,
                      const Color(0xFFB8860B),
                    ),
                  if (goldBreakdownLines.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.amber.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: Colors.amber.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'تفصيل العيارات',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: Colors.black87,
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
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text(
                        'لا توجد قيم مالية أو وزنية مسجلة.',
                        style: TextStyle(color: Colors.black54),
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
                    accentColor: Colors.blueGrey,
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
                accentColor: Colors.indigo,
                child: Text(
                  voucher['description'],
                  style: const TextStyle(
                    fontSize: 16,
                    color: Colors.black87,
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
                accentColor: Colors.teal,
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

            if (voucher['notes'] != null &&
                voucher['notes'].toString().isNotEmpty)
              _buildSectionCard(
                title: 'ملاحظات',
                icon: Icons.sticky_note_2_outlined,
                accentColor: Colors.brown,
                child: Text(
                  voucher['notes'],
                  style: const TextStyle(
                    fontSize: 14,
                    color: Colors.black87,
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
                    accentColor: Colors.indigo,
                    child: Column(
                      children: [
                        // رأس الجدول
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              const Expanded(flex: 5, child: Text('الحساب', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12))),
                              const SizedBox(width: 6,
                                child: Text('', style: TextStyle(fontSize: 11))),
                              const Expanded(flex: 3, child: Text('مدين', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.red))),
                              const SizedBox(width: 4),
                              const Expanded(flex: 3, child: Text('دائن', textAlign: TextAlign.end, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.green))),
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
                          final amtStr   = '${amt.toStringAsFixed(amtType == 'gold' ? 3 : 2)} $unit';

                          return Container(
                            margin: const EdgeInsets.only(bottom: 4),
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                            decoration: BoxDecoration(
                              color: isDebit
                                  ? Colors.red.shade50
                                  : Colors.green.shade50,
                              borderRadius: BorderRadius.circular(7),
                              border: Border(
                                right: BorderSide(
                                  color: isDebit ? Colors.red.shade300 : Colors.green.shade300,
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
                                      Text(accName, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
                                      if (accNum.isNotEmpty)
                                        Text(accNum, style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    isDebit ? amtStr : '',
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.red),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  flex: 3,
                                  child: Text(
                                    !isDebit ? amtStr : '',
                                    textAlign: TextAlign.end,
                                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: Colors.green),
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
              accentColor: Colors.blueGrey,
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
                accentColor: const Color(0xFFFFB300),
                child: Column(
                  children: [
                    ...voucher['audit_log'].map<Widget>(
                      (entry) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFFFF8E1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.person,
                                size: 18,
                                color: Colors.grey[700],
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
                                      style: TextStyle(
                                        color: Colors.grey[700],
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (entry['action'] != null)
                                Text(
                                  '(${entry['action']})',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: Colors.black54,
                                  ),
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
        color: Colors.white,
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
                        color: Colors.black.withValues(alpha: 0.18),
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
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              voucherNumber,
                              style: TextStyle(
                                color: Colors.black.withValues(alpha: 0.65),
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
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? theme.AppColors.error
            : theme.AppColors.primaryGold,
        behavior: SnackBarBehavior.floating,
      ),
    );
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
        return theme.AppColors.success;
      case 'cancelled':
      case 'voided':
        return theme.AppColors.error;
      case 'active':
      default:
        return const Color(0xFF607D8B);
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
        color: Colors.white,
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
                  style: TextStyle(
                    fontSize: 17,
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
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
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
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
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
