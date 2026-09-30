import 'package:flutter/material.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';

/// Unified alerts dialog for the admin dashboard.
/// Replaces the standalone SystemAlertsScreen + InvoiceApprovalScreen flow.
class AlertsDialog extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final VoidCallback? onCountChanged;

  const AlertsDialog({
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
      barrierColor: Colors.black.withValues(alpha: 0.52),
      builder: (_) => Directionality(
        textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
        child: AlertsDialog(
          api: api,
          isArabic: isArabic,
          onCountChanged: onCountChanged,
        ),
      ),
    );
  }

  @override
  State<AlertsDialog> createState() => _AlertsDialogState();
}

class _AlertsDialogState extends State<AlertsDialog> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _alerts = [];
  int _total = 0;

  /// Which alert id is currently expanded for full details.
  int? _expandedAlertId;

  /// Ids currently being approved (invoice_approval type).
  final Set<int> _approvingIds = {};

  /// Ids currently being marked reviewed.
  final Set<int> _reviewingIds = {};

  /// Ids that have just been actioned (slide-out animation).
  final Set<int> _doneIds = {};

  @override
  void initState() {
    super.initState();
    _loadAlerts();
  }

  Future<void> _loadAlerts() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await widget.api.getSystemAlerts(
        severity: 'critical',
        reviewed: false,
      );
      final rows = payload['alerts'];
      if (!mounted) return;
      final list = rows is List
          ? rows
                .whereType<Map>()
                .map((r) => Map<String, dynamic>.from(r))
                .toList()
          : <Map<String, dynamic>>[];
      setState(() {
        _alerts = list;
        _total = list.length;
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

  Future<void> _markReviewed(int alertId) async {
    if (_reviewingIds.contains(alertId)) return;
    setState(() => _reviewingIds.add(alertId));
    try {
      await widget.api.reviewSystemAlert(alertId);
      if (!mounted) return;
      await _animateRemove(alertId);
      widget.onCountChanged?.call();
    } catch (e) {
      if (!mounted) return;
      setState(() => _reviewingIds.remove(alertId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _approveInvoice(Map<String, dynamic> alert) async {
    final alertId = alert['id'] as int?;
    final invoiceId = _asInt(alert['entity_id']);
    if (invoiceId == null) return;
    if (_approvingIds.contains(invoiceId)) return;

    final isAr = widget.isArabic;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
        child: AlertDialog(
          title: Text(
            isAr ? 'تأكيد الاعتماد' : 'Confirm Approval',
            style: const TextStyle(fontFamily: 'Cairo', fontWeight: FontWeight.w700),
          ),
          content: Text(
            isAr
                ? 'سيتم ترحيل القيود المحاسبية وتعديل أرصدة الخزائن. هل أنت متأكد؟'
                : 'This will post journal entries and update safebox balances. Are you sure?',
            style: const TextStyle(fontFamily: 'Cairo'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(isAr ? 'إلغاء' : 'Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(isAr ? 'اعتماد وترحيل' : 'Approve & Post'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _approvingIds.add(invoiceId));
    try {
      await widget.api.approveInvoice(invoiceId);
      if (!mounted) return;
      // Also mark alert as reviewed if we have an alertId.
      if (alertId != null) {
        try {
          await widget.api.reviewSystemAlert(alertId);
        } catch (_) {}
      }
      if (!mounted) return;
      await _animateRemove(alertId ?? invoiceId);
      widget.onCountChanged?.call();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isAr ? 'تم اعتماد وترحيل الفاتورة بنجاح' : 'Invoice approved and posted',
              style: const TextStyle(fontFamily: 'Cairo'),
            ),
            backgroundColor: AppColors.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _approvingIds.remove(invoiceId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppColors.error,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  Future<void> _animateRemove(int id) async {    setState(() => _doneIds.add(id));
    await Future.delayed(const Duration(milliseconds: 320));
    if (!mounted) return;
    setState(() {
      _alerts.removeWhere((a) => (a['id'] as int?) == id || (a['entity_id'] as int?) == id);
      _total = _alerts.length;
      _doneIds.remove(id);
      _reviewingIds.remove(id);
    });
    if (_alerts.isEmpty && mounted) {
      await Future.delayed(const Duration(milliseconds: 200));
      if (mounted) Navigator.of(context).pop();
    }
  }

  // ── helpers ──────────────────────────────────────────────────────────────

  static double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  static int? _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  static bool _asBool(dynamic v) {
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final s = v.trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'yes';
    }
    return false;
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso);
      return DateFormat('yyyy/MM/dd HH:mm', 'en').format(dt);
    } catch (_) {
      return iso;
    }
  }

  String _relativeTime(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso);
      final diff = DateTime.now().difference(dt);
      final isAr = widget.isArabic;
      if (diff.inMinutes < 1) return isAr ? 'الآن' : 'now';
      if (diff.inMinutes < 60) return isAr ? 'منذ ${diff.inMinutes}د' : '${diff.inMinutes}m ago';
      if (diff.inHours < 24) return isAr ? 'منذ ${diff.inHours}س' : '${diff.inHours}h ago';
      return isAr ? 'منذ ${diff.inDays}ي' : '${diff.inDays}d ago';
    } catch (_) {
      return '';
    }
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final isAr = widget.isArabic;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 680),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
            borderRadius: BorderRadius.circular(18),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 28,
                offset: const Offset(0, 10),
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

  // ── header ────────────────────────────────────────────────────────────────

  Widget _buildHeader(ThemeData theme, bool isDark, bool isAr) {
    final badgeColor = _total > 0 ? AppColors.error : AppColors.success;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEEEEEE),
          ),
        ),
      ),
      child: Row(
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _total > 0
                      ? Icons.notifications_active_rounded
                      : Icons.notifications_off_outlined,
                  color: badgeColor,
                  size: 22,
                ),
              ),
              if (_total > 0)
                PositionedDirectional(
                  top: -2,
                  end: -2,
                  child: Container(
                    width: 17,
                    height: 17,
                    decoration: const BoxDecoration(
                      color: AppColors.error,
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        _total > 9 ? '9+' : '$_total',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          fontFamily: 'Cairo',
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isAr ? 'تنبيهات النظام' : 'System Alerts',
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: isDark ? Colors.white : const Color(0xFF212121),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _loading
                      ? (isAr ? 'جارِ التحميل...' : 'Loading...')
                      : _total > 0
                      ? (isAr
                          ? '$_total ${_total == 1 ? 'تنبيه يحتاج' : 'تنبيهات تحتاج'} مراجعة'
                          : '$_total ${_total == 1 ? 'alert needs' : 'alerts need'} review')
                      : (isAr ? 'لا توجد تنبيهات حرجة' : 'No critical alerts'),
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 12,
                    color: isDark ? const Color(0xFFBDBDBD) : const Color(0xFF757575),
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
            color: isDark ? const Color(0xFFBDBDBD) : const Color(0xFF616161),
          ),
        ],
      ),
    );
  }

  // ── body ──────────────────────────────────────────────────────────────────

  Widget _buildBody(ThemeData theme, bool isDark, bool isAr) {
    if (_loading) {
      return const SizedBox(
        height: 200,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2.5)),
      );
    }
    if (_error != null) {
      return _buildErrorState(theme, isDark, isAr);
    }
    if (_alerts.isEmpty) {
      return _buildEmptyState(theme, isDark, isAr);
    }

    return AnimationLimiter(
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        shrinkWrap: true,
        itemCount: _alerts.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          indent: 12,
          endIndent: 12,
          color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFF0F0F0),
        ),
        itemBuilder: (context, index) => AnimationConfiguration.staggeredList(
          position: index,
          duration: const Duration(milliseconds: 240),
          child: SlideAnimation(
            verticalOffset: 12,
            child: FadeInAnimation(
              child: _buildAlertRow(_alerts[index], isDark, isAr),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildAlertRow(Map<String, dynamic> alert, bool isDark, bool isAr) {
    final alertId = _asInt(alert['id']) ?? 0;
    final alertType = (alert['alert_type'] ?? '').toString().trim();
    final isInvoiceType = alertType == 'invoice_approval';

    final isDone = _doneIds.contains(alertId);

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: isDone ? 0 : 1,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 300),
        offset: isDone ? const Offset(0.4, 0) : Offset.zero,
        child: isInvoiceType
            ? _buildInvoiceAlertRow(alert, isDark, isAr)
            : _buildShiftAlertRow(alert, isDark, isAr),
      ),
    );
  }

  // ── invoice_approval alert row ────────────────────────────────────────────

  Widget _buildInvoiceAlertRow(Map<String, dynamic> alert, bool isDark, bool isAr) {
    final alertId = _asInt(alert['id']) ?? 0;
    final invoiceId = _asInt(alert['entity_id']);
    final invoiceNumber = (alert['entity_number'] ?? invoiceId ?? '—').toString();

    final details = alert['details'];
    final dm = details is Map ? Map<String, dynamic>.from(details) : <String, dynamic>{};

    final invoiceType = (dm['invoice_type'] ?? '').toString();
    final discountPct = dm.containsKey('discount_pct') ? _asDouble(dm['discount_pct']) : null;
    final thresholdPct = dm.containsKey('threshold_pct') ? _asDouble(dm['threshold_pct']) : null;
    final approvalReasons = (dm['approval_reasons'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const <String>[];

    final createdBy = (alert['created_by'] ?? dm['created_by'] ?? '').toString().trim();
    final createdAt = alert['created_at']?.toString();

    final isApproving = invoiceId != null && _approvingIds.contains(invoiceId);
    final isReviewing = _reviewingIds.contains(alertId);
    final isExpanded = _expandedAlertId == alertId;
    final auth = context.read<AuthProvider>();

    final theme = Theme.of(context);
    const accent = AppColors.warning;

    return _AlertRowShell(
      isDark: isDark,
      accentColor: accent,
      badgeIcon: Icons.receipt_long_rounded,
      badgeLabel: isAr ? 'فاتورة' : 'Inv.',
      title: (alert['title'] ?? (isAr ? 'فاتورة تحتاج اعتماداً' : 'Invoice needs approval'))
          .toString(),
      subtitle: isAr
          ? 'فاتورة #$invoiceNumber${invoiceType.isNotEmpty ? ' · $invoiceType' : ''}'
          : 'Invoice #$invoiceNumber${invoiceType.isNotEmpty ? ' · $invoiceType' : ''}',
      createdBy: createdBy,
      relativeTime: _relativeTime(createdAt),
      isExpanded: isExpanded,
      onExpandTap: () => setState(
        () => _expandedAlertId = isExpanded ? null : alertId,
      ),
      expandedContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detailRow(theme, isDark, isAr ? 'رقم الفاتورة' : 'Invoice #', invoiceNumber),
          if (invoiceType.isNotEmpty)
            _detailRow(theme, isDark, isAr ? 'نوع الفاتورة' : 'Type', invoiceType),
          if (discountPct != null)
            _detailRow(
              theme,
              isDark,
              isAr ? 'نسبة الخصم' : 'Discount',
              '${discountPct.toStringAsFixed(2)}%${thresholdPct != null ? ' (${isAr ? 'الحد' : 'limit'}: ${thresholdPct.toStringAsFixed(2)}%)' : ''}',
            ),
          if (approvalReasons.isNotEmpty)
            _detailRow(
              theme,
              isDark,
              isAr ? 'أسباب الاعتماد' : 'Reasons',
              approvalReasons.map((r) => _reasonLabel(r, isAr)).join('، '),
            ),
          if (createdBy.isNotEmpty)
            _detailRow(theme, isDark, isAr ? 'أُنشئ بواسطة' : 'Created by', createdBy),
          if (createdAt != null && createdAt.isNotEmpty)
            _detailRow(theme, isDark, isAr ? 'التاريخ' : 'Date', _formatDate(createdAt)),
        ],
      ),
      actions: Row(
        children: [
          if (auth.isManager && invoiceId != null)
            _ActionChip(
              label: isApproving
                  ? (isAr ? 'جارِ الاعتماد...' : 'Approving...')
                  : (isAr ? '✓ اعتماد وترحيل' : '✓ Approve & Post'),
              color: AppColors.success,
              isPrimary: true,
              isLoading: isApproving,
              onTap: (isApproving || isReviewing) ? null : () => _approveInvoice(alert),
            ),
          const SizedBox(width: 6),
          _ActionChip(
            label: isReviewing
                ? (isAr ? 'جارِ...' : '...')
                : (isAr ? 'تمت المراجعة' : 'Mark reviewed'),
            color: isDark ? const Color(0xFFBDBDBD) : const Color(0xFF616161),
            isPrimary: false,
            isLoading: isReviewing,
            onTap: (isApproving || isReviewing) ? null : () => _markReviewed(alertId),
          ),
        ],
      ),
    );
  }

  // ── shift/closing alert row ───────────────────────────────────────────────

  Widget _buildShiftAlertRow(Map<String, dynamic> alert, bool isDark, bool isAr) {
    final alertId = _asInt(alert['id']) ?? 0;
    final severity = (alert['severity'] ?? '').toString().toLowerCase();
    final isCritical = severity == 'critical';

    final details = alert['details'];
    final dm = details is Map ? Map<String, dynamic>.from(details) : <String, dynamic>{};
    final diffs = dm['diffs'] is Map ? Map<String, dynamic>.from(dm['diffs'] as Map) : <String, dynamic>{};
    final flags = dm['flags'] is Map ? Map<String, dynamic>.from(dm['flags'] as Map) : <String, dynamic>{};

    final cashCritical = _asBool(flags['cash_critical']);
    final goldCritical = _asBool(flags['gold_critical']);
    final cashDiff = _asDouble(diffs['cash_difference']);
    final goldDiff = diffs['gold_pure_24k_difference'] == null
        ? null
        : _asDouble(diffs['gold_pure_24k_difference']);

    final entityNumber = (alert['entity_number'] ??
            ((dm['shift'] is Map) ? (dm['shift'] as Map)['entity_number'] : null) ??
            '')
        .toString();

    final createdBy = (alert['created_by'] ?? dm['created_by'] ?? '').toString().trim();
    final createdAt = alert['created_at']?.toString();

    final isReviewing = _reviewingIds.contains(alertId);
    final isExpanded = _expandedAlertId == alertId;

    final accent = isCritical ? AppColors.error : AppColors.warning;
    final theme = Theme.of(context);

    String typeLabel;
    if (cashCritical && goldCritical) {
      typeLabel = isAr ? 'كاش+ذهب' : 'Cash+Gold';
    } else if (cashCritical) {
      typeLabel = isAr ? 'كاش' : 'Cash';
    } else if (goldCritical) {
      typeLabel = isAr ? 'ذهب' : 'Gold';
    } else {
      typeLabel = isAr ? 'تنبيه' : 'Alert';
    }

    String subtitle;
    if (cashCritical && goldCritical) {
      subtitle = isAr
          ? 'عجز نقدي وذهبي في وردية $entityNumber'
          : 'Cash & gold deficit – Shift $entityNumber';
    } else if (cashCritical) {
      subtitle = isAr
          ? 'عجز نقدي في وردية $entityNumber'
          : 'Cash deficit – Shift $entityNumber';
    } else if (goldCritical) {
      subtitle = isAr
          ? 'عجز ذهبي في وردية $entityNumber'
          : 'Gold deficit – Shift $entityNumber';
    } else {
      subtitle = isAr ? 'وردية $entityNumber' : 'Shift $entityNumber';
    }

    return _AlertRowShell(
      isDark: isDark,
      accentColor: accent,
      badgeIcon: Icons.report_problem_outlined,
      badgeLabel: typeLabel,
      title: (alert['title'] ?? subtitle).toString(),
      subtitle: subtitle,
      createdBy: createdBy,
      relativeTime: _relativeTime(createdAt),
      isExpanded: isExpanded,
      onExpandTap: () => setState(
        () => _expandedAlertId = isExpanded ? null : alertId,
      ),
      expandedContent: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (entityNumber.isNotEmpty)
            _detailRow(theme, isDark, isAr ? 'رقم الوردية' : 'Shift #', entityNumber),
          if (cashCritical)
            _detailRow(
              theme,
              isDark,
              isAr ? 'فرق الكاش' : 'Cash diff',
              '${cashDiff >= 0 ? '+' : ''}${cashDiff.toStringAsFixed(2)} ${isAr ? 'ر.س' : 'SAR'}',
              valueColor: AppColors.error,
            ),
          if (goldCritical && goldDiff != null)
            _detailRow(
              theme,
              isDark,
              isAr ? 'فرق الذهب (24k)' : 'Gold diff (24k)',
              '${goldDiff >= 0 ? '+' : ''}${goldDiff.toStringAsFixed(3)} ${isAr ? 'جم' : 'g'}',
              valueColor: AppColors.error,
            ),
          if (createdBy.isNotEmpty)
            _detailRow(theme, isDark, isAr ? 'المسؤول' : 'Operator', createdBy),
          if (createdAt != null && createdAt.isNotEmpty)
            _detailRow(theme, isDark, isAr ? 'التاريخ' : 'Date', _formatDate(createdAt)),
        ],
      ),
      actions: Row(
        children: [
          _ActionChip(
            label: isReviewing
                ? (isAr ? 'جارِ...' : '...')
                : (isAr ? '✓ تمت المراجعة' : '✓ Mark reviewed'),
            color: AppColors.success,
            isPrimary: true,
            isLoading: isReviewing,
            onTap: isReviewing ? null : () => _markReviewed(alertId),
          ),
        ],
      ),
    );
  }

  // ── empty / error ──────────────────────────────────────────────────────────

  Widget _buildEmptyState(ThemeData theme, bool isDark, bool isAr) {
    return Padding(
      padding: const EdgeInsets.all(44),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: AppColors.success.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.notifications_off_outlined,
              size: 34,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            isAr ? 'لا توجد تنبيهات حرجة' : 'No critical alerts',
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : const Color(0xFF212121),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isAr ? 'جميع التنبيهات خضعت للمراجعة' : 'All alerts have been reviewed',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 12,
              color: isDark ? const Color(0xFFBDBDBD) : const Color(0xFF757575),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(ThemeData theme, bool isDark, bool isAr) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline_rounded, size: 40, color: AppColors.error),
          const SizedBox(height: 12),
          Text(
            isAr ? 'تعذّر تحميل التنبيهات' : 'Failed to load alerts',
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _loadAlerts,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(isAr ? 'إعادة المحاولة' : 'Retry',
                style: const TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }

  // ── footer ────────────────────────────────────────────────────────────────

  Widget _buildFooter(ThemeData theme, bool isDark, bool isAr) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: isDark ? const Color(0xFF2D2D2D) : const Color(0xFFEEEEEE),
          ),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              isAr
                  ? 'تُعرض التنبيهات الحرجة غير المُراجعة فقط'
                  : 'Showing unreviewed critical alerts only',
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11,
                color: isDark ? const Color(0xFF8E8E93) : const Color(0xFF8E8E93),
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _loading ? null : _loadAlerts,
            icon: const Icon(Icons.refresh_rounded, size: 16),
            label: Text(isAr ? 'تحديث' : 'Refresh',
                style: const TextStyle(fontFamily: 'Cairo', fontSize: 12)),
          ),
        ],
      ),
    );
  }

  // ── detail row helper ─────────────────────────────────────────────────────

  Widget _detailRow(
    ThemeData theme,
    bool isDark,
    String label,
    String value, {
    Color? valueColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                color: isDark ? const Color(0xFF8E8E93) : const Color(0xFF6E6E73),
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontFamily: 'Cairo',
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: valueColor ??
                    (isDark ? Colors.white.withValues(alpha: 0.88) : const Color(0xFF1C1C1E)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _reasonLabel(String key, bool isAr) {
    const labels = {
      'above_live_price': ('شراء فوق السعر المباشر', 'Above live price'),
      'below_cost': ('بيع تحت التكلفة', 'Below cost'),
      'large_discount': ('خصم كبير', 'Large discount'),
      'partial_payment': ('دفع جزئي', 'Partial payment'),
      'high_value': ('مبلغ مرتفع', 'High value'),
    };
    final pair = labels[key];
    if (pair == null) return key;
    return isAr ? pair.$1 : pair.$2;
  }
}

// ── reusable row shell ────────────────────────────────────────────────────────

class _AlertRowShell extends StatelessWidget {
  final bool isDark;
  final Color accentColor;
  final IconData badgeIcon;
  final String badgeLabel;
  final String title;
  final String subtitle;
  final String createdBy;
  final String relativeTime;
  final bool isExpanded;
  final VoidCallback onExpandTap;
  final Widget expandedContent;
  final Widget actions;

  const _AlertRowShell({
    required this.isDark,
    required this.accentColor,
    required this.badgeIcon,
    required this.badgeLabel,
    required this.title,
    required this.subtitle,
    required this.createdBy,
    required this.relativeTime,
    required this.isExpanded,
    required this.onExpandTap,
    required this.expandedContent,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onExpandTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Badge
                Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: accentColor.withValues(alpha: 0.22),
                    ),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(badgeIcon, size: 16, color: accentColor),
                      const SizedBox(height: 2),
                      Text(
                        badgeLabel,
                        style: TextStyle(
                          fontFamily: 'Cairo',
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: accentColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white : const Color(0xFF1C1C1E),
                              ),
                            ),
                          ),
                          if (relativeTime.isNotEmpty)
                            Text(
                              relativeTime,
                              style: const TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 10.5,
                                color: Color(0xFF9E9E9E),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$subtitle${createdBy.isNotEmpty ? ' · $createdBy' : ''}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Cairo',
                                fontSize: 11,
                                color: isDark
                                    ? const Color(0xFFBDBDBD)
                                    : const Color(0xFF757575),
                              ),
                            ),
                          ),
                          Icon(
                            isExpanded
                                ? Icons.keyboard_arrow_up_rounded
                                : Icons.keyboard_arrow_down_rounded,
                            size: 18,
                            color: const Color(0xFF9E9E9E),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      actions,
                    ],
                  ),
                ),
              ],
            ),
            // Expanded details
            AnimatedSize(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOutCubic,
              child: isExpanded
                  ? Padding(
                      padding: const EdgeInsetsDirectional.only(
                        start: 58,
                        top: 10,
                        bottom: 4,
                      ),
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF2C2C2E)
                              : const Color(0xFFF8F8FA),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: accentColor.withValues(alpha: 0.18),
                          ),
                        ),
                        child: expandedContent,
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }
}

// ── action chip ──────────────────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool isPrimary;
  final bool isLoading;
  final VoidCallback? onTap;

  const _ActionChip({
    required this.label,
    required this.color,
    required this.isPrimary,
    required this.isLoading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: isPrimary
              ? color.withValues(alpha: isLoading ? 0.08 : 0.14)
              : color.withValues(alpha: 0.07),
          borderRadius: BorderRadius.circular(6),
          border: isPrimary
              ? Border.all(color: color.withValues(alpha: 0.28))
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
}
