import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:provider/provider.dart';
import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../providers/auth_provider.dart';
import '../screens/posting_management_screen.dart';

class PendingApprovalsDialog extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final VoidCallback? onCountChanged;

  const PendingApprovalsDialog({
    super.key,
    required this.api,
    required this.isArabic,
    this.onCountChanged,
  });

  static Future<void> show({
    required BuildContext context,
    required ApiService api,
    required bool isArabic,
    VoidCallback? onCountChanged,
  }) {
    return showDialog(
      context: context,
      barrierDismissible: true,
      barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.50),
      builder: (_) => Directionality(
        textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: PendingApprovalsDialog(
          api: api,
          isArabic: isArabic,
          onCountChanged: onCountChanged,
        ),
      ),
    );
  }

  @override
  State<PendingApprovalsDialog> createState() => _PendingApprovalsDialogState();
}

class _PendingApprovalsDialogState extends State<PendingApprovalsDialog> {
  // الألوان من الثيم (ثيم-٠): تتبع الوضعين.
  ColorScheme get _cs => Theme.of(context).colorScheme;
  AppSemanticColors get _tone => AppSemanticColors.of(context);

  bool _loading = true;
  String? _error;

  List<Map<String, dynamic>> _reservations = [];
  List<Map<String, dynamic>> _invoices = [];
  int _totalReservations = 0;
  int _totalInvoices = 0;

  /// The system itself -- a silent scheduler (SCHED-004). Computed by the
  /// server on every read; it has no action and leaves when the scheduler beats.
  List<Map<String, dynamic>> _systemAlerts = [];

  // Invoice action tracking
  final Set<int> _postingIds = {};
  final Set<int> _justPostedIds = {};
  final Set<int> _rejectingIds = {};
  final Set<int> _justRejectedIds = {};

  // Reservation action tracking
  final Set<int> _settlingIds = {};
  final Set<int> _justSettledIds = {};

  // Expanded reservation IDs
  final Set<int> _expandedIds = {};

  @override
  void initState() {
    super.initState();
    _loadList();
  }

  Future<void> _loadList() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await widget.api.getPendingActions();
      if (!mounted) return;
      setState(() {
        _reservations = (result['pending_reservations'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _invoices = (result['pending_invoices'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _systemAlerts = (result['system_alerts'] as List? ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        _totalReservations =
            (result['total_pending_reservations'] as num?)?.toInt() ?? 0;
        _totalInvoices =
            (result['total_pending_invoices'] as num?)?.toInt() ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Things awaiting a decision. A system alert is not one: it has its own
  /// card and its own chip on the home screen.
  int get _totalCount => _totalReservations + _totalInvoices;

  // ─────────────── Reservation actions ───────────────

  Future<void> _settleReservation(Map<String, dynamic> res) async {
    final id = res['id'] as int;
    if (_settlingIds.contains(id)) return;
    final isAr = widget.isArabic;

    final code = res['reservation_code']?.toString() ?? '';
    final officeName = res['office_name']?.toString() ?? '';
    final weight = (res['weight_remaining_main_karat'] as num?)?.toDouble() ?? 0.0;
    final total = (res['total_amount'] as num?)?.toDouble() ?? 0.0;
    final pricePerGram = (res['price_per_gram'] as num?)?.toDouble();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          isAr ? 'تأكيد تسوية الحجز' : 'Confirm Settlement',
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _confirmRow(isAr ? 'الكود' : 'Code', code),
            _confirmRow(isAr ? 'المكتب' : 'Office', officeName),
            _confirmRow(
              isAr ? 'الوزن المتبقي' : 'Remaining Weight',
              '${weight.toStringAsFixed(3)} جم',
            ),
            _confirmRow(
              isAr ? 'الإجمالي' : 'Total',
              '${NumberFormat('#,##0', 'en').format(total.round())} ر.س',
            ),
            const SizedBox(height: 8),
            Text(
              isAr
                  ? 'سيتم إنشاء فاتورة شراء وإرسالها للاعتماد.'
                  : 'A purchase invoice will be created for approval.',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                color: _tone.warning.fg,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(isAr ? 'إلغاء' : 'Cancel',
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: _tone.ready.fg),
            child: Text(
              isAr ? 'تنفيذ التسوية' : 'Execute',
              style: const TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _settlingIds.add(id));
    try {
      await widget.api.settleOfficeReservation(
        id,
        executionPricePerGram: pricePerGram,
      );
      if (!mounted) return;
      setState(() => _justSettledIds.add(id));
      await Future.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      setState(() {
        _reservations.removeWhere((r) => r['id'] == id);
        _totalReservations = (_totalReservations - 1).clamp(0, 9999);
        _settlingIds.remove(id);
        _justSettledIds.remove(id);
        _expandedIds.remove(id);
      });
      widget.onCountChanged?.call();
      // Reload to pick up the newly created invoice
      await _loadList();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            isAr
                ? 'تم تنفيذ التسوية — الفاتورة بانتظار الاعتماد'
                : 'Settlement executed — invoice awaiting approval',
            style: TextStyle(fontFamily: 'Cairo', color: _cs.onPrimary),
          ),
          backgroundColor: _tone.ready.fg,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _settlingIds.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          isAr ? 'فشل التسوية: $e' : 'Settlement failed: $e',
          style: TextStyle(fontFamily: 'Cairo', color: _cs.onError),
        ),
        backgroundColor: _cs.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  // ─────────────── Invoice actions ───────────────

  Future<void> _postInvoice(Map<String, dynamic> invoice) async {
    final id = invoice['id'] as int;
    if (_postingIds.contains(id)) return;

    final String postedBy =
        Provider.of<AuthProvider>(context, listen: false).username;

    setState(() => _postingIds.add(id));
    try {
      await widget.api.postInvoice(id, postedBy);
      if (!mounted) return;
      setState(() => _justPostedIds.add(id));
      await Future.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      setState(() {
        _invoices.removeWhere((inv) => inv['id'] == id);
        _totalInvoices = (_totalInvoices - 1).clamp(0, 9999);
        _postingIds.remove(id);
        _justPostedIds.remove(id);
      });
      widget.onCountChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            widget.isArabic
                ? 'تم ترحيل ${invoice['invoice_number']}'
                : 'Posted ${invoice['invoice_number']}',
            style: TextStyle(fontFamily: 'Cairo', color: _cs.onPrimary),
          ),
          backgroundColor: _tone.ready.fg,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ));
      }
      if (_invoices.isEmpty && _reservations.isEmpty && _systemAlerts.isEmpty && mounted) {
        await Future.delayed(const Duration(milliseconds: 300));
        if (mounted) Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _postingIds.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          widget.isArabic ? 'فشل الترحيل: $e' : 'Posting failed: $e',
          style: TextStyle(fontFamily: 'Cairo', color: _cs.onError),
        ),
        backgroundColor: _cs.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  Future<void> _rejectInvoice(Map<String, dynamic> invoice) async {
    final id = invoice['id'] as int;
    if (_rejectingIds.contains(id)) return;
    final isAr = widget.isArabic;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(
          isAr ? 'رفض الفاتورة' : 'Reject Invoice',
          style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w800),
        ),
        content: Text(
          isAr
              ? 'هل تريد رفض الفاتورة ${invoice['invoice_number']}؟\nسيعود الحجز المرتبط بها إلى حالة الانتظار.'
              : 'Reject invoice ${invoice['invoice_number']}?\nLinked reservation will return to pending.',
          style: const TextStyle(fontFamily: 'Cairo'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(isAr ? 'إلغاء' : 'Cancel',
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: _tone.blocked.fg),
            child: Text(
              isAr ? 'رفض' : 'Reject',
              style: const TextStyle(
                  fontFamily: 'Cairo', fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _rejectingIds.add(id));
    try {
      await widget.api.rejectInvoice(id);
      if (!mounted) return;
      setState(() => _justRejectedIds.add(id));
      await Future.delayed(const Duration(milliseconds: 280));
      if (!mounted) return;
      setState(() {
        _invoices.removeWhere((inv) => inv['id'] == id);
        _totalInvoices = (_totalInvoices - 1).clamp(0, 9999);
        _rejectingIds.remove(id);
        _justRejectedIds.remove(id);
      });
      widget.onCountChanged?.call();
      // Reload to pick up any reservation that returned to pending
      await _loadList();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
            isAr
                ? 'تم رفض ${invoice['invoice_number']} — الحجز عاد للانتظار'
                : 'Rejected ${invoice['invoice_number']} — reservation reset to pending',
            style: TextStyle(fontFamily: 'Cairo', color: _cs.onError),
          ),
          backgroundColor: _cs.error,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _rejectingIds.remove(id));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          isAr ? 'فشل الرفض: $e' : 'Reject failed: $e',
          style: TextStyle(fontFamily: 'Cairo', color: _cs.onError),
        ),
        backgroundColor: _cs.error,
        behavior: SnackBarBehavior.floating,
      ));
    }
  }

  void _viewInvoiceDetails(Map<String, dynamic> invoice) {
    final isAr = widget.isArabic;
    final reason = (invoice['approval_reason_message'] as String?) ?? '';
    final invoiceNumber = invoice['invoice_number']?.toString() ?? '';
    final total = (invoice['total_amount'] as num?)?.toDouble() ?? 0.0;
    final totalWeight = (invoice['total_weight'] as num?)?.toDouble() ?? 0.0;
    final goldSubtotal = (invoice['gold_subtotal'] as num?)?.toDouble() ?? 0.0;
    final goldType = invoice['gold_type']?.toString() ?? '';
    final party = invoice['party_name']?.toString() ?? '';
    final creator = invoice['created_by_name']?.toString() ?? '';
    final paymentMethod = invoice['payment_method']?.toString() ?? '';
    final karatLines = (invoice['karat_lines'] as List?) ?? [];
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final goldTypeLabel = goldType == 'scrap'
        ? (isAr ? 'كسر' : 'Scrap')
        : (isAr ? 'جديد' : 'New');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: (isDark ? _cs.surfaceContainerLow : _cs.surfaceContainerLowest),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: EdgeInsets.fromLTRB(
            20, 12, 20, MediaQuery.of(context).viewInsets.bottom + 28),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: theme.dividerColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      invoiceNumber,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (goldType.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: goldType == 'scrap'
                            ? _tone.bronze.fg.withValues(alpha: 0.12)
                            : _cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        goldTypeLabel,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: goldType == 'scrap'
                              ? _tone.bronze.fg
                              : _cs.primary,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              if (party.isNotEmpty)
                _detailRow(isAr ? 'الطرف' : 'Party', party, theme),
              if (creator.isNotEmpty)
                _detailRow(isAr ? 'المنشئ' : 'Created by', creator, theme),
              if (paymentMethod.isNotEmpty)
                _detailRow(
                    isAr ? 'وسيلة الدفع' : 'Payment', paymentMethod, theme),
              _detailRow(isAr ? 'إجمالي الفاتورة' : 'Total',
                  '${total.toStringAsFixed(2)} ر.س', theme),
              if (goldSubtotal > 0 && goldSubtotal != total)
                _detailRow(isAr ? 'قيمة الذهب' : 'Gold value',
                    '${goldSubtotal.toStringAsFixed(2)} ر.س', theme),
              if (totalWeight > 0)
                _detailRow(isAr ? 'إجمالي الوزن' : 'Total weight',
                    '${totalWeight.toStringAsFixed(3)} جم', theme),
              if (karatLines.isNotEmpty) ...[
                const Divider(height: 22),
                Text(
                  isAr ? 'تفاصيل العيارات' : 'Karat details',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: theme.hintColor),
                ),
                const SizedBox(height: 8),
                ...karatLines.map((kl) {
                  final karat = kl['karat'] ?? 0;
                  final weight =
                      (kl['weight_grams'] as num?)?.toDouble() ?? 0.0;
                  final ppg =
                      (kl['price_per_gram'] as num?)?.toDouble() ?? 0.0;
                  final value =
                      (kl['gold_value'] as num?)?.toDouble() ?? 0.0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: _cs.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text('${karat}k',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: _cs.primary)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                            child: Text('${weight.toStringAsFixed(3)} جم',
                                style: const TextStyle(fontSize: 12))),
                        Text('${ppg.toStringAsFixed(2)} ر.س/جم',
                            style: TextStyle(
                                fontSize: 12, color: theme.hintColor)),
                        const SizedBox(width: 8),
                        Text('${value.toStringAsFixed(2)} ر.س',
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  );
                }),
              ],
              const Divider(height: 22),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    reason.isNotEmpty
                        ? Icons.warning_amber_rounded
                        : Icons.info_outline,
                    size: 18,
                    color:
                        reason.isNotEmpty ? _tone.warning.fg : theme.hintColor,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      reason.isNotEmpty
                          ? reason
                          : (isAr
                              ? 'تحتاج اعتماداً قبل الترحيل'
                              : 'Requires approval before posting'),
                      style: TextStyle(
                        fontSize: 13,
                        color: reason.isNotEmpty
                            ? _tone.warning.fg
                            : theme.hintColor,
                        fontWeight: reason.isNotEmpty
                            ? FontWeight.w600
                            : FontWeight.normal,
                        height: 1.4,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openPostingManagement() async {
    Navigator.of(context).pop();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) =>
            PostingManagementScreen(isArabic: widget.isArabic),
      ),
    );
    widget.onCountChanged?.call();
  }

  // ─────────────── Build ───────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isAr = widget.isArabic;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 640),
        child: Container(
          decoration: BoxDecoration(
            color: (isDark ? _cs.surfaceContainerLow : _cs.surfaceContainerLowest),
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _cs.shadow.withValues(alpha: 0.20),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHeader(theme, isDark, isAr),
              Flexible(child: _buildBody(theme, isDark, isAr)),
              _buildFooter(theme, isDark, isAr),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── Header ───────────────

  Widget _buildHeader(ThemeData theme, bool isDark, bool isAr) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: _cs.outlineVariant,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: _cs.primary.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.pending_actions_rounded,
              color: _cs.primary,
              size: 22,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isAr ? 'المعلّقات بانتظار الإجراء' : 'Pending Actions',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: _cs.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _loading
                      ? (isAr ? 'جارِ التحميل...' : 'Loading...')
                      : _totalCount == 0
                          ? (_systemAlerts.isNotEmpty
                              ? (isAr ? 'عطل تشغيل يحتاج تدخلًا على الخادم' : 'A system fault needs attention')
                              : (isAr ? 'لا توجد إجراءات معلقة' : 'No pending actions'))
                          : (isAr
                              ? '$_totalCount ${_totalCount == 1 ? 'إجراء ينتظر' : 'إجراء ينتظر'} مراجعتك'
                              : '$_totalCount ${_totalCount == 1 ? 'item needs' : 'items need'} review'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: _cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 22),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: isAr ? 'إغلاق' : 'Close',
            color: _cs.onSurfaceVariant,
          ),
        ],
      ),
    );
  }

  // ─────────────── Body ───────────────

  Widget _buildBody(ThemeData theme, bool isDark, bool isAr) {
    if (_loading) {
      return SizedBox(
        height: 200,
        child: Center(
          child: CircularProgressIndicator(
            color: _cs.primary,
            strokeWidth: 2.5,
          ),
        ),
      );
    }

    if (_error != null) {
      return _buildErrorState(theme, isAr);
    }

    if (_reservations.isEmpty && _invoices.isEmpty && _systemAlerts.isEmpty) {
      return _buildEmptyState(theme, isAr);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Section 0: the system itself (SCHED-004) ──
          for (final alert in _systemAlerts) _buildSystemAlertCard(alert, isDark, isAr),

          // ── Section 1: حجوزات بانتظار التسوية ──
          if (_reservations.isNotEmpty) ...[
            _buildSectionHeader(
              icon: Icons.inventory_2_outlined,
              label: isAr
                  ? 'حجوزات بانتظار التسوية ($_totalReservations)'
                  : 'Pending Settlement ($_totalReservations)',
              color: _cs.primary,
              isDark: isDark,
            ),
            AnimationLimiter(
              child: Column(
                children: List.generate(_reservations.length, (index) {
                  return AnimationConfiguration.staggeredList(
                    position: index,
                    duration: const Duration(milliseconds: 240),
                    child: SlideAnimation(
                      verticalOffset: 12,
                      child: FadeInAnimation(
                        child: _buildReservationCard(
                            _reservations[index], isDark, isAr),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],

          // ── Separator ──
          if (_reservations.isNotEmpty && _invoices.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Divider(
                height: 1,
                thickness: 1,
                color: _cs.outlineVariant,
              ),
            ),

          // ── Section 2: فواتير بانتظار الاعتماد ──
          if (_invoices.isNotEmpty) ...[
            _buildSectionHeader(
              icon: Icons.receipt_long_outlined,
              label: isAr
                  ? 'فواتير بانتظار الاعتماد ($_totalInvoices)'
                  : 'Pending Approval ($_totalInvoices)',
              color: _tone.blocked.fg,
              isDark: isDark,
            ),
            AnimationLimiter(
              child: Column(
                children: List.generate(_invoices.length, (index) {
                  return AnimationConfiguration.staggeredList(
                    position: index,
                    duration: const Duration(milliseconds: 240),
                    child: SlideAnimation(
                      verticalOffset: 12,
                      child: FadeInAnimation(
                        child: _buildInvoiceRow(
                            _invoices[index], isDark, isAr),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSystemAlertCard(Map<String, dynamic> alert, bool isDark, bool isAr) {
    final title = (alert['title'] ?? (isAr ? 'المجدول متوقف' : 'Scheduler down')).toString();
    final message = (alert['message'] ?? '').toString();
    final whatToDo = (alert['what_to_do'] ?? '').toString();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _tone.blocked.fg.withValues(alpha: isDark ? 0.18 : 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _tone.blocked.fg.withValues(alpha: 0.45)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.power_off_rounded, size: 18, color: _tone.blocked.fg),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: _tone.blocked.fg,
                  ),
                ),
              ),
            ],
          ),
          if (message.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(message, style: const TextStyle(fontFamily: 'Cairo', fontSize: 12.5)),
          ],
          if (whatToDo.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              whatToDo,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                color: _cs.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            isAr ? 'يختفي وحده حين يعود المجدول' : 'Clears by itself when the scheduler is back',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11,
              color: _cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionHeader({
    required IconData icon,
    required String label,
    required Color color,
    required bool isDark,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── Reservation Card ───────────────

  Widget _buildReservationCard(
      Map<String, dynamic> res, bool isDark, bool isAr) {
    final id = res['id'] as int;
    final isExpanded = _expandedIds.contains(id);
    final isSettling = _settlingIds.contains(id);
    final isJustSettled = _justSettledIds.contains(id);

    final code = res['reservation_code']?.toString() ?? '—';
    final officeName = res['office_name']?.toString() ?? '—';
    final karat = res['karat']?.toString() ?? '';
    final weight =
        (res['weight_remaining_main_karat'] as num?)?.toDouble() ?? 0.0;
    final total = (res['total_amount'] as num?)?.toDouble() ?? 0.0;
    final paid = (res['paid_amount'] as num?)?.toDouble() ?? 0.0;
    final pricePerGram = (res['price_per_gram'] as num?)?.toDouble() ?? 0.0;
    final contactPerson = res['contact_person']?.toString() ?? '';
    final notes = res['notes']?.toString() ?? '';
    final reservationDate = res['reservation_date']?.toString();
    final relativeTime = _formatRelativeTime(reservationDate, isAr);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 280),
      opacity: isJustSettled ? 0 : 1,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 280),
        offset: isJustSettled ? const Offset(1, 0) : Offset.zero,
        child: InkWell(
          onTap: () => setState(() {
            if (isExpanded) {
              _expandedIds.remove(id);
            } else {
              _expandedIds.add(id);
            }
          }),
          child: Padding(
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Collapsed row ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Karat badge
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: _cs.primary.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Center(
                        child: Text(
                          karat.isNotEmpty ? '${karat}k' : '—',
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                            color: _cs.primary,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  code,
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: _cs.onSurface,
                                  ),
                                ),
                              ),
                              Text(
                                NumberFormat('#,##0', 'en')
                                    .format(total.round()),
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 14,
                                  fontWeight: FontWeight.w800,
                                  color: _cs.primary,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  '$officeName · ${weight.toStringAsFixed(3)} جم',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'Cairo',
                                    fontSize: 11,
                                    color: _cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                relativeTime,
                                style: TextStyle(
                                  fontFamily: 'Cairo',
                                  fontSize: 10.5,
                                  color: _cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      isExpanded
                          ? Icons.keyboard_arrow_up_rounded
                          : Icons.keyboard_arrow_down_rounded,
                      size: 20,
                      color: _cs.onSurfaceVariant,
                    ),
                  ],
                ),

                // ── Expanded details ──
                AnimatedSize(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOut,
                  child: isExpanded
                      ? Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Detail rows
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: _cs.surfaceContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Column(
                                  children: [
                                    _resDetailRow(
                                      isAr ? 'السعر / جم' : 'Price/g',
                                      '${pricePerGram.toStringAsFixed(2)} ر.س',
                                      isDark,
                                    ),
                                    _resDetailRow(
                                      isAr ? 'المدفوع' : 'Paid',
                                      '${NumberFormat('#,##0', 'en').format(paid.round())} ر.س',
                                      isDark,
                                    ),
                                    _resDetailRow(
                                      isAr ? 'المتبقي' : 'Balance',
                                      '${NumberFormat('#,##0', 'en').format((total - paid).round())} ر.س',
                                      isDark,
                                    ),
                                    if (contactPerson.isNotEmpty)
                                      _resDetailRow(
                                        isAr ? 'جهة الاتصال' : 'Contact',
                                        contactPerson,
                                        isDark,
                                      ),
                                    if (notes.isNotEmpty)
                                      _resDetailRow(
                                        isAr ? 'ملاحظات' : 'Notes',
                                        notes,
                                        isDark,
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),
                              // Action buttons
                              _buildActionButton(
                                label: isSettling
                                    ? (isAr ? 'جارِ التسوية...' : 'Settling...')
                                    : (isAr ? 'تنفيذ التسوية' : 'Execute Settlement'),
                                color: _tone.ready.fg,
                                isPrimary: true,
                                isLoading: isSettling,
                                onTap: isSettling ? null : () => _settleReservation(res),
                              ),
                            ],
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _resDetailRow(String label, String value, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 90,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: _cs.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: _cs.onSurface,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── Invoice Row ───────────────

  Widget _buildInvoiceRow(
    Map<String, dynamic> invoice,
    bool isDark,
    bool isAr,
  ) {
    final id = invoice['id'] as int;
    final isPosting = _postingIds.contains(id);
    final isJustPosted = _justPostedIds.contains(id);
    final isRejecting = _rejectingIds.contains(id);
    final isJustRejected = _justRejectedIds.contains(id);

    final type = (invoice['invoice_type'] ?? '').toString();
    final number = (invoice['invoice_number'] ?? '—').toString();
    final amount = (invoice['total_amount'] as num?)?.toDouble() ?? 0;
    final party = (invoice['party_name'] ?? '—').toString();
    final createdBy = (invoice['created_by_name'] ?? '—').toString();
    final createdAt = invoice['created_at']?.toString();

    final (typeLabel, typeColor) = _getTypeInfo(type, isAr);
    final relativeTime = _formatRelativeTime(createdAt, isAr);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 280),
      opacity: (isJustPosted || isJustRejected) ? 0 : 1,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 280),
        offset: (isJustPosted || isJustRejected)
            ? Offset(isAr ? 1 : -1, 0)
            : Offset.zero,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: typeColor.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Center(
                  child: Text(
                    typeLabel,
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      color: typeColor,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            number,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: _cs.onSurface,
                            ),
                          ),
                        ),
                        Text(
                          NumberFormat('#,##0', 'en').format(amount.round()),
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: typeColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$party · $createdBy',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontFamily: 'Cairo',
                              fontSize: 11,
                              color: _cs.onSurfaceVariant,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          relativeTime,
                          style: TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 10.5,
                            color: _cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildActionButton(
                          label: isPosting
                              ? (isAr ? 'جارِ الترحيل...' : 'Posting...')
                              : (isAr ? '✓ ترحيل' : '✓ Post'),
                          color: _tone.ready.fg,
                          isPrimary: true,
                          isLoading: isPosting,
                          onTap: (isPosting || isRejecting)
                              ? null
                              : () => _postInvoice(invoice),
                        ),
                        const SizedBox(width: 6),
                        _buildActionButton(
                          label: isRejecting
                              ? (isAr ? 'جارِ الرفض...' : 'Rejecting...')
                              : (isAr ? '✕ رفض' : '✕ Reject'),
                          color: _tone.blocked.fg,
                          isPrimary: false,
                          isLoading: isRejecting,
                          onTap: (isPosting || isRejecting)
                              ? null
                              : () => _rejectInvoice(invoice),
                        ),
                        const SizedBox(width: 6),
                        _buildActionButton(
                          label: isAr ? 'تفاصيل' : 'Details',
                          color: _cs.onSurfaceVariant,
                          isPrimary: false,
                          isLoading: false,
                          onTap: (isPosting || isRejecting)
                              ? null
                              : () => _viewInvoiceDetails(invoice),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─────────────── Shared widgets ───────────────

  Widget _buildActionButton({
    required String label,
    required Color color,
    required bool isPrimary,
    required bool isLoading,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isPrimary
              ? color.withValues(alpha: isLoading ? 0.10 : 0.15)
              : color.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: isPrimary
              ? Border.all(color: color.withValues(alpha: 0.30))
              : null,
        ),
        child: isLoading
            ? SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.8,
                  valueColor: AlwaysStoppedAnimation(color),
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
      ),
    );
  }

  Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 80,
            child: Text(label,
                style: TextStyle(
                    fontFamily: 'Cairo', fontSize: 12, color: _cs.onSurfaceVariant)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _detailRow(String label, String value, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(label,
                style: TextStyle(fontSize: 12, color: theme.hintColor)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(
                    fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  // ─────────────── Empty / Error ───────────────

  Widget _buildEmptyState(ThemeData theme, bool isAr) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: _tone.ready.fg.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.check_circle_rounded,
              size: 36,
              color: _tone.ready.fg,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isAr ? 'لا توجد إجراءات معلقة' : 'All clear!',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: _cs.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isAr
                ? 'لا توجد حجوزات أو فواتير بانتظار الإجراء'
                : 'No reservations or invoices pending action',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color:
                  _cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ThemeData theme, bool isAr) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded,
              size: 40, color: _tone.blocked.fg),
          const SizedBox(height: 12),
          Text(
            isAr ? 'تعذر التحميل' : 'Could not load',
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loadList,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(
              isAr ? 'إعادة المحاولة' : 'Retry',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
          ),
        ],
      ),
    );
  }

  // ─────────────── Footer ───────────────

  Widget _buildFooter(ThemeData theme, bool isDark, bool isAr) {
    final totalShown = _reservations.length + _invoices.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color:
                _cs.outlineVariant,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            isAr
                ? 'يعرض $totalShown من $_totalCount'
                : 'Showing $totalShown of $_totalCount',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 11.5,
              color: _cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (_invoices.isNotEmpty)
            InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: _openPostingManagement,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      isAr ? 'إدارة الترحيل' : 'Posting Management',
                      style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: _tone.gold.fg,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      isAr
                          ? Icons.arrow_back_ios_new_rounded
                          : Icons.arrow_forward_ios_rounded,
                      size: 11,
                      color: _tone.gold.fg,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─────────────── Helpers ───────────────

  (String, Color) _getTypeInfo(String type, bool isAr) {
    switch (type) {
      case 'بيع':
      case 'sale':
        return (isAr ? 'بيع' : 'Sale', _tone.invoiceSale.fg);
      case 'scrap_sale':
        return (isAr ? 'بيع كسر' : 'Scrap Sale', _tone.invoiceSaleScrap.fg);
      case 'شراء':
      case 'purchase':
        return (isAr ? 'شراء' : 'Purchase', _tone.invoicePurchase.fg);
      case 'شراء من عميل':
        return (isAr ? 'شراء عميل' : 'Cust. Buy', _tone.invoicePurchaseScrap.fg);
      case 'scrap_purchase':
      case 'شراء خردة':
        return (
          isAr ? 'شراء كسر' : 'Scrap Buy',
          _tone.invoicePurchaseScrap.fg
        );
      case 'مرتجع بيع':
      case 'sales_return':
        return (
          isAr ? 'مرتجع بيع' : 'Sale Ret.',
          _tone.invoiceReturn.fg
        );
      case 'مرتجع شراء':
      case 'purchase_return':
        return (
          isAr ? 'مرتجع شراء' : 'Purch. Ret.',
          _tone.invoiceReturn.fg
        );
      default:
        return (isAr ? 'فاتورة' : 'Invoice', _tone.gold.fg);
    }
  }

  String _formatRelativeTime(String? iso, bool isAr) {
    if (iso == null) return '';
    final dt = DateTime.tryParse(iso);
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return isAr ? 'الآن' : 'now';
    if (diff.inMinutes < 60) {
      return isAr ? 'منذ ${diff.inMinutes} د' : '${diff.inMinutes}m ago';
    }
    if (diff.inHours < 24) {
      return isAr ? 'منذ ${diff.inHours} س' : '${diff.inHours}h ago';
    }
    if (diff.inDays < 7) {
      return isAr ? 'منذ ${diff.inDays} ي' : '${diff.inDays}d ago';
    }
    return DateFormat('dd/MM', 'en').format(dt);
  }
}
