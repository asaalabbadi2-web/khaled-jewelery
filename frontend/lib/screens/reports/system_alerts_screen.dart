import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/auth_provider.dart';
import 'invoice_approval_screen.dart';
import '../../utils/invoice_type_label.dart';

class SystemAlertsScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SystemAlertsScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<SystemAlertsScreen> createState() => _SystemAlertsScreenState();
}

class _SystemAlertsScreenState extends State<SystemAlertsScreen> {
  late Future<List<Map<String, dynamic>>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetchAlerts();
  }

  Future<List<Map<String, dynamic>>> _fetchAlerts() async {
    final payload = await widget.api.getSystemAlerts(
      severity: 'critical',
      reviewed: false,
    );

    final rows = payload['alerts'];
    if (rows is List) {
      return rows
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
    }

    return const [];
  }

  Future<void> _reload() async {
    setState(() {
      _future = _fetchAlerts();
    });
  }

  Future<void> _markReviewed(int alertId) async {
    try {
      await widget.api.reviewSystemAlert(alertId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic ? 'تمت المراجعة' : 'Marked as reviewed',
          ),
        ),
      );
      await _reload();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '';
    try {
      final dt = DateTime.parse(iso);
      final fmt = DateFormat('yyyy/MM/dd HH:mm', widget.isArabic ? 'ar' : 'en');
      return fmt.format(dt);
    } catch (_) {
      return iso;
    }
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  int? _asInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool _asBool(dynamic value) {
    if (value is bool) return value;
    if (value is num) return value != 0;
    if (value is String) {
      final s = value.trim().toLowerCase();
      return s == 'true' || s == '1' || s == 'yes' || s == 'y';
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'تنبيهات النظام' : 'System Alerts'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: isArabic ? 'تحديث' : 'Refresh',
              onPressed: _reload,
            ),
          ],
        ),
        body: SafeArea(
          child: FutureBuilder<List<Map<String, dynamic>>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }

              if (snapshot.hasError) {
                return _buildError(snapshot.error.toString());
              }

              final alerts = snapshot.data ?? const [];
              if (alerts.isEmpty) {
                return _buildEmpty();
              }

              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: alerts.length,
                separatorBuilder: (context, index) =>
                    const SizedBox(height: 12),
                itemBuilder: (context, index) => _buildAlertCard(alerts[index]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    final isArabic = widget.isArabic;
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_off_outlined,
              size: 48,
              color: theme.hintColor,
            ),
            const SizedBox(height: 12),
            Text(
              isArabic
                  ? 'لا توجد تنبيهات حرجة غير مُراجعة'
                  : 'No unreviewed critical alerts',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(String message) {
    final isArabic = widget.isArabic;
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 12),
            Text(
              isArabic ? 'تعذّر تحميل التنبيهات' : 'Failed to load alerts',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.hintColor,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
              label: Text(isArabic ? 'إعادة المحاولة' : 'Try again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertCard(Map<String, dynamic> alert) {
    final alertType = (alert['alert_type'] ?? '').toString().trim();
    if (alertType == 'invoice_approval') {
      return _buildInvoiceApprovalAlertCard(alert);
    }

    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final severity = (alert['severity'] ?? '').toString().toLowerCase();
    final isCritical = severity == 'critical';

    final details = alert['details'];
    final detailsMap = details is Map
        ? Map<String, dynamic>.from(details)
        : <String, dynamic>{};
    final diffs = detailsMap['diffs'] is Map
        ? Map<String, dynamic>.from(detailsMap['diffs'] as Map)
        : <String, dynamic>{};
    final flags = detailsMap['flags'] is Map
        ? Map<String, dynamic>.from(detailsMap['flags'] as Map)
        : <String, dynamic>{};

    final cashCritical = _asBool(flags['cash_critical']);
    final goldCritical = _asBool(flags['gold_critical']);

    final cashDiff = _asDouble(diffs['cash_difference']);
    final goldDiff = diffs['gold_pure_24k_difference'] == null
        ? null
        : _asDouble(diffs['gold_pure_24k_difference']);

    final entityNumber =
        (alert['entity_number'] ??
                ((detailsMap['shift'] is Map)
                    ? (detailsMap['shift'] as Map)['entity_number']
                    : null) ??
                '')
            .toString();

    final String summaryLine;
    if (cashCritical && goldCritical) {
      summaryLine = isArabic
          ? 'عجز نقدي وذهب يتجاوز الحد في وردية $entityNumber'
          : 'Cash and gold deficit exceeded threshold (Shift $entityNumber)';
    } else if (cashCritical) {
      summaryLine = isArabic
          ? 'عجز نقدي يتجاوز الحد في وردية $entityNumber'
          : 'Cash deficit exceeded threshold (Shift $entityNumber)';
    } else if (goldCritical) {
      summaryLine = isArabic
          ? 'عجز ذهب يتجاوز الحد في وردية $entityNumber'
          : 'Gold deficit exceeded threshold (Shift $entityNumber)';
    } else {
      summaryLine = isArabic
          ? 'تنبيه في وردية $entityNumber'
          : 'Alert (Shift $entityNumber)';
    }

    final createdAt = _formatDate(alert['created_at']?.toString());

    final title = (alert['title'] ?? '').toString().trim();
    final displayTitle = title.isNotEmpty
        ? title
        : (isArabic ? 'تنبيه' : 'Alert');

    final isReviewed = _asBool(alert['is_reviewed']);
    final alertId = alert['id'];

    final background = isCritical ? theme.colorScheme.errorContainer : null;
    final foreground = isCritical ? theme.colorScheme.onErrorContainer : null;

    String typeLabel;
    if (cashCritical && goldCritical) {
      typeLabel = isArabic ? 'كاش + ذهب' : 'Cash + Gold';
    } else if (cashCritical) {
      typeLabel = isArabic ? 'كاش' : 'Cash';
    } else if (goldCritical) {
      typeLabel = isArabic ? 'ذهب' : 'Gold';
    } else {
      typeLabel = isArabic ? 'غير محدد' : 'Unknown';
    }

    return Card(
      elevation: 0,
      color: background,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.report_problem_outlined,
                  color: isCritical
                      ? theme.colorScheme.error
                      : theme.colorScheme.primary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    displayTitle,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                if (createdAt.isNotEmpty)
                  Text(
                    createdAt,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: foreground ?? theme.hintColor,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              summaryLine,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            _kvRow(
              label: isArabic ? 'رقم الوردية' : 'Shift',
              value: entityNumber.isNotEmpty
                  ? entityNumber
                  : (isArabic ? 'غير متاح' : 'N/A'),
              valueColor: foreground,
            ),
            const SizedBox(height: 6),
            _kvRow(
              label: isArabic ? 'نوع العجز' : 'Deficit type',
              value: typeLabel,
              valueColor: foreground,
            ),
            const SizedBox(height: 8),
            if (cashCritical)
              _kvRow(
                label: isArabic ? 'فرق الكاش' : 'Cash diff',
                value: (cashDiff >= 0)
                    ? '+${cashDiff.toStringAsFixed(2)}'
                    : cashDiff.toStringAsFixed(2),
                valueColor: foreground,
              ),
            if (goldCritical && goldDiff != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: _kvRow(
                  label: isArabic
                      ? 'فرق الذهب الصافي (24k)'
                      : 'Pure gold diff (24k)',
                  value: (goldDiff >= 0)
                      ? '+${goldDiff.toStringAsFixed(3)} جم'
                      : '${goldDiff.toStringAsFixed(3)} جم',
                  valueColor: foreground,
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    isReviewed
                        ? (isArabic ? 'تمت المراجعة' : 'Reviewed')
                        : (isArabic ? 'غير مُراجع' : 'Unreviewed'),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground ?? theme.hintColor,
                    ),
                  ),
                ),
                if (!isReviewed && alertId is int)
                  ElevatedButton.icon(
                    onPressed: () => _markReviewed(alertId),
                    icon: const Icon(Icons.check_circle_outline),
                    label: Text(isArabic ? 'تمت المراجعة' : 'Mark reviewed'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInvoiceApprovalAlertCard(Map<String, dynamic> alert) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;
    final auth = context.watch<AuthProvider>();

    final details = alert['details'];
    final detailsMap = details is Map
        ? Map<String, dynamic>.from(details)
        : <String, dynamic>{};

    final alertId = _asInt(alert['id']);
    final invoiceId = _asInt(alert['entity_id']);
    final invoiceNumber = (alert['entity_number'] ?? invoiceId ?? '').toString();
    final invoiceType = (detailsMap['invoice_type'] ?? '').toString();

    final discountPct = detailsMap.containsKey('discount_pct')
        ? _asDouble(detailsMap['discount_pct'])
        : null;
    final thresholdPct = detailsMap.containsKey('threshold_pct')
        ? _asDouble(detailsMap['threshold_pct'])
        : null;

    final isReviewed = _asBool(alert['is_reviewed']);
    final createdAt = _formatDate(alert['created_at']?.toString());

    final background = theme.colorScheme.errorContainer;
    final foreground = theme.colorScheme.onErrorContainer;

    Future<void> openDetails() async {
      if (invoiceId == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              isArabic ? 'معرف الفاتورة غير متاح' : 'Invoice id missing',
            ),
          ),
        );
        return;
      }

      final result = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => InvoiceApprovalScreen(
            api: widget.api,
            isArabic: widget.isArabic,
            invoiceId: invoiceId,
            alertId: alertId,
            alertDetails: detailsMap,
          ),
        ),
      );

      if (result == true) {
        await _reload();
      }
    }

    return Card(
      elevation: 0,
      color: background,
      child: InkWell(
        onTap: openDetails,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.verified_user_outlined, color: theme.colorScheme.error),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      (alert['title'] ?? (isArabic ? 'فاتورة تحتاج اعتماد' : 'Invoice needs approval'))
                          .toString(),
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: foreground,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  if (createdAt.isNotEmpty)
                    Text(
                      createdAt,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                isArabic
                    ? 'فاتورة #$invoiceNumber تحتاج اعتماد قبل الترحيل'
                    : 'Invoice #$invoiceNumber requires approval before posting',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (invoiceType.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    isArabic ? 'النوع: ${invoiceTypeLabelOf(invoiceType)}' : 'Type: $invoiceType',
                    style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
                  ),
                ),
              if (discountPct != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    thresholdPct != null
                        ? (isArabic
                            ? 'نسبة الخصم: ${discountPct.toStringAsFixed(2)}% (الحد ${thresholdPct.toStringAsFixed(2)}%)'
                            : 'Discount: ${discountPct.toStringAsFixed(2)}% (threshold ${thresholdPct.toStringAsFixed(2)}%)')
                        : (isArabic
                            ? 'نسبة الخصم: ${discountPct.toStringAsFixed(2)}%'
                            : 'Discount: ${discountPct.toStringAsFixed(2)}%'),
                    style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
                  ),
                ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      isReviewed
                          ? (isArabic ? 'تمت المراجعة' : 'Reviewed')
                          : (isArabic ? 'غير مُراجع' : 'Unreviewed'),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: foreground,
                      ),
                    ),
                  ),
                  if (!isReviewed && alertId != null)
                    ElevatedButton.icon(
                      onPressed: () => _markReviewed(alertId),
                      icon: const Icon(Icons.check_circle_outline),
                      label: Text(isArabic ? 'تمت المراجعة' : 'Mark reviewed'),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (auth.isManager)
                Text(
                  isArabic ? 'اضغط لفتح التفاصيل' : 'Tap to open details',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: foreground.withOpacity(0.85),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kvRow({
    required String label,
    required String value,
    Color? valueColor,
  }) {
    final theme = Theme.of(context);

    return Row(
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: valueColor,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }
}
