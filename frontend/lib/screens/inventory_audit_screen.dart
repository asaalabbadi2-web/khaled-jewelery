import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/inventory_models.dart';
import '../services/inventory_service.dart';
import '../theme/app_theme.dart';
import '../widgets/bucket_balance_card.dart' show formatWeight;
import '../theme/app_semantic_colors.dart';

/// The theme's colours (ADR-038): the scheme and the semantic tones.
ColorScheme _cs(BuildContext context) => Theme.of(context).colorScheme;
AppSemanticColors _tn(BuildContext context) => AppSemanticColors.of(context);

class InventoryAuditScreen extends StatefulWidget {
  const InventoryAuditScreen({super.key});

  @override
  State<InventoryAuditScreen> createState() => _InventoryAuditScreenState();
}

class _InventoryAuditScreenState extends State<InventoryAuditScreen>
    with SingleTickerProviderStateMixin {
  final _svc = InventoryService(ApiService());

  ReconciliationReport? _recon;
  HealthReport? _health;
  bool _loading = true;
  String? _error;
  bool _showMismatchOnly = false;

  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final results = await Future.wait([
        _svc.getReconciliation(),
        _svc.getHealth(),
      ]);
      setState(() {
        _recon = results[0] as ReconciliationReport;
        _health = results[1] as HealthReport;
        _loading = false;
      });
    } on InventoryApiException catch (e) {
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        appBar: AppBar(
          title: const Text('مركز التدقيق'),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _load,
              tooltip: 'تحديث',
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            labelColor: Theme.of(context).appBarTheme.foregroundColor,
            unselectedLabelColor:
                Theme.of(context).appBarTheme.foregroundColor?.withValues(alpha: 0.7),
            indicatorColor: Theme.of(context).appBarTheme.foregroundColor,
            tabs: const [
              Tab(text: 'المطابقة', icon: Icon(Icons.table_rows_outlined, size: 18)),
              Tab(text: 'الصحة', icon: Icon(Icons.health_and_safety_outlined, size: 18)),
            ],
          ),
        ),
        body: _loading
            ? Center(child: CircularProgressIndicator(color: _cs(context).primary))
            : _error != null
                ? _ErrorView(message: _error!, onRetry: _load)
                : TabBarView(
                    controller: _tabs,
                    children: [
                      _ReconciliationTab(
                        report: _recon!,
                        showMismatchOnly: _showMismatchOnly,
                        onToggleFilter: (v) =>
                            setState(() => _showMismatchOnly = v),
                        onRefresh: _load,
                      ),
                      _HealthTab(report: _health!),
                    ],
                  ),
      ),
    );
  }
}

// ── Tab 1: Reconciliation ─────────────────────────────────────────────────────

class _ReconciliationTab extends StatelessWidget {
  const _ReconciliationTab({
    required this.report,
    required this.showMismatchOnly,
    required this.onToggleFilter,
    required this.onRefresh,
  });
  final ReconciliationReport report;
  final bool showMismatchOnly;
  final ValueChanged<bool> onToggleFilter;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    // The filter: what still needs classifying (the count classifies it).
    final rows = showMismatchOnly
        ? report.rows.where((r) => r.unclassifiedGrams.abs() > 0.0005).toList()
        : report.rows;

    return RefreshIndicator(
      onRefresh: onRefresh,
      color: _cs(context).primary,
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: _ReconSummaryCard(report: report)),
          SliverToBoxAdapter(
            child: _FilterRow(
              showMismatchOnly: showMismatchOnly,
              mismatchCount:
                  report.rows.where((r) => r.unclassifiedGrams.abs() > 0.0005).length,
              onToggle: onToggleFilter,
              generatedAt: report.generatedAt,
            ),
          ),
          if (rows.isEmpty)
            const SliverFillRemaining(
              child: Center(child: Text('لا يوجد رصيد بلا تصنيف')),
            )
          else
            SliverToBoxAdapter(
              child: _ReconciliationTable(rows: rows),
            ),
        ],
      ),
    );
  }
}

class _ReconSummaryCard extends StatelessWidget {
  const _ReconSummaryCard({required this.report});
  final ReconciliationReport report;

  @override
  Widget build(BuildContext context) {
    final isClean = report.isClean;
    final color = isClean ? _tn(context).ready.fg : _tn(context).warning.fg;

    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            isClean ? Icons.check_circle_rounded : Icons.warning_amber_rounded,
            color: color,
            size: 36,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isClean
                      ? 'توزيع المخزون على التصنيفات سليم'
                      : 'توزيع يخالف سطره — راجع نتائج الفحص الليلي',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: color,
                  ),
                ),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 12,
                  children: [
                    _StatChip(
                      label: 'موقع × عيار',
                      value: '${report.rows.length}',
                      color: _cs(context).primary,
                    ),
                    if (report.violations > 0)
                      _StatChip(
                        label: 'توزيع يخالف سطره',
                        value: '${report.violations}',
                        color: _cs(context).error,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({required this.label, required this.value, required this.color});
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 11, color: _cs(context).onSurfaceVariant)),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ],
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.showMismatchOnly,
    required this.mismatchCount,
    required this.onToggle,
    required this.generatedAt,
  });
  final bool showMismatchOnly;
  final int mismatchCount;
  final ValueChanged<bool> onToggle;
  final DateTime generatedAt;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          if (mismatchCount > 0)
            GestureDetector(
              onTap: () => onToggle(!showMismatchOnly),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: showMismatchOnly
                      ? _tn(context).warning.fg
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: showMismatchOnly
                        ? _tn(context).warning.fg
                        : _cs(context).outlineVariant,
                  ),
                ),
                child: Text(
                  'بلا تصنيف فقط ($mismatchCount)',
                  style: TextStyle(
                    color: showMismatchOnly ? _cs(context).surface : _cs(context).onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: showMismatchOnly
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
              ),
            ),
          const Spacer(),
          Text(
            'تاريخ التقرير: ${_fmt(generatedAt)}',
            style: TextStyle(fontSize: 10, color: _cs(context).onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _fmt(DateTime dt) {
    return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class _ReconciliationTable extends StatelessWidget {
  const _ReconciliationTable({required this.rows});
  final List<ReconciliationRow> rows;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        children: [
          // Header
          _TableHeader(),
          const Divider(height: 1),
          // Rows
          ...rows.map((r) => _TableRow(row: r)),
        ],
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _cs(context).surfaceContainerHigh,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
      ),
      child: const Row(
        children: [
          Expanded(flex: 3, child: _HeaderCell('الموقع')),
          Expanded(flex: 2, child: _HeaderCell('الدفاتر')),
          Expanded(flex: 2, child: _HeaderCell('المصنّف')),
          Expanded(flex: 2, child: _HeaderCell('آخر جرد')),
          SizedBox(width: 64),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.bold,
        color: _cs(context).onSurfaceVariant,
      ),
    );
  }
}

class _TableRow extends StatelessWidget {
  const _TableRow({required this.row});
  final ReconciliationRow row;

  @override
  Widget build(BuildContext context) {
    final karatColor = _tn(context).karat(((row.karat) as num).round()).fg;
    final unclassified = row.unclassifiedGrams.abs() > 0.0005;
    final counted = row.lastCountAt;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: _cs(context).outlineVariant),
          right: unclassified
              ? BorderSide(color: _tn(context).warning.fg, width: 3)
              : BorderSide.none,
        ),
      ),
      child: Row(
        children: [
          // Location and karat
          Expanded(
            flex: 3,
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: karatColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'ع${row.karat.toStringAsFixed(0)}',
                    style: TextStyle(
                      color: karatColor,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    row.safeBoxName ?? '#${row.safeBoxId}',
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
          // What the books hold
          Expanded(
            flex: 2,
            child: Text(
              formatWeight(row.booksGrams),
              style: const TextStyle(fontSize: 12),
            ),
          ),
          // How much of it is classified
          Expanded(
            flex: 2,
            child: Row(
              children: [
                Text(
                  formatWeight(row.classifiedGrams),
                  style: TextStyle(
                    fontSize: 12,
                    color: unclassified ? _tn(context).warning.fg : null,
                  ),
                ),
                const SizedBox(width: 4),
                _StatusDot(ok: !unclassified, na: false),
              ],
            ),
          ),
          // The last approved count
          Expanded(
            flex: 2,
            child: Text(
              counted != null
                  ? '${counted.year}/${counted.month}/${counted.day}'
                  : '—',
              style: TextStyle(fontSize: 12, color: counted == null ? _cs(context).outline : null),
            ),
          ),
          SizedBox(
            width: 64,
            child: (row.lastCountVariance ?? 0).abs() > 0.0005
                ? _VarianceBadge(variance: row.lastCountVariance!)
                : null,
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.ok, required this.na});
  final bool ok;
  final bool na;

  @override
  Widget build(BuildContext context) {
    if (na) return const SizedBox(width: 8, height: 8);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: ok ? _tn(context).ready.fg : _cs(context).error,
        shape: BoxShape.circle,
      ),
    );
  }
}

class _VarianceBadge extends StatelessWidget {
  const _VarianceBadge({required this.variance});
  final double variance;

  @override
  Widget build(BuildContext context) {
    final isPos = variance >= 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: isPos
            ? _tn(context).ready.fg.withValues(alpha: 0.15)
            : _cs(context).error.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '${isPos ? '+' : ''}${formatWeight(variance)}',
        style: TextStyle(
          fontSize: 9,
          color: isPos ? _tn(context).ready.fg : _cs(context).error,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// ── Tab 2: Health ─────────────────────────────────────────────────────────────

class _HealthTab extends StatelessWidget {
  const _HealthTab({required this.report});
  final HealthReport report;

  @override
  Widget build(BuildContext context) {
    final issueMetrics = report.metrics.where((m) => !m.ok).toList();
    final okMetrics = report.metrics.where((m) => m.ok).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        // Overall status banner
        _HealthBanner(
          hasIssues: report.hasIssues,
          generatedAt: report.generatedAt,
          metricCount: report.metrics.length,
        ),
        const SizedBox(height: 16),

        // Issues first
        if (issueMetrics.isNotEmpty) ...[
          _SectionLabel(
            label: 'تحتاج مراجعة',
            count: issueMetrics.length,
            color: _cs(context).error,
          ),
          const SizedBox(height: 8),
          ...issueMetrics.map((m) => _MetricCard(metric: m)),
          const SizedBox(height: 16),
        ],

        // Healthy metrics
        if (okMetrics.isNotEmpty) ...[
          _SectionLabel(
            label: 'سليمة',
            count: okMetrics.length,
            color: _tn(context).ready.fg,
          ),
          const SizedBox(height: 8),
          ...okMetrics.map((m) => _MetricCard(metric: m)),
        ],
      ],
    );
  }
}

class _HealthBanner extends StatelessWidget {
  const _HealthBanner({
    required this.hasIssues,
    required this.generatedAt,
    required this.metricCount,
  });
  final bool hasIssues;
  final DateTime generatedAt;
  final int metricCount;

  @override
  Widget build(BuildContext context) {
    final color = hasIssues ? _cs(context).error : _tn(context).ready.fg;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(
            hasIssues
                ? Icons.health_and_safety_outlined
                : Icons.health_and_safety_rounded,
            color: color,
            size: 40,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  hasIssues ? 'توجد مشكلات تحتاج تدخل' : 'المحرك في حالة جيدة',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: color,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$metricCount مؤشر — ${generatedAt.hour.toString().padLeft(2, '0')}:${generatedAt.minute.toString().padLeft(2, '0')}',
                  style: TextStyle(fontSize: 11, color: _cs(context).onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel({
    required this.label,
    required this.count,
    required this.color,
  });
  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 4,
          height: 16,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: color,
            fontSize: 13,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            '$count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.metric});
  final HealthMetric metric;

  @override
  Widget build(BuildContext context) {
    final color = metric.ok ? _tn(context).ready.fg : _cs(context).error;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: _cs(context).shadow.withValues(alpha: 0.03),
            blurRadius: 4,
            offset: const Offset(0, 1),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 2),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  metric.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                if (metric.detail.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    metric.detail,
                    style: TextStyle(fontSize: 11, color: _cs(context).onSurfaceVariant),
                  ),
                ],
              ],
            ),
          ),
          Icon(
            metric.ok ? Icons.check_circle_rounded : Icons.cancel_rounded,
            color: color,
            size: 18,
          ),
        ],
      ),
    );
  }
}

// ── Shared ────────────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, size: 48, color: _tn(context).warning.fg),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _cs(context).primary,
                foregroundColor: _cs(context).onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
