import 'dart:ui' show ImageFilter;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_staggered_animations/flutter_staggered_animations.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../models/safe_box_model.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import '../audit_log_screen.dart';
import '../safe_boxes_screen.dart';
import 'gold_price_history_report_screen.dart';
import 'sales_vs_purchases_trend_report_screen.dart';
import 'system_alerts_screen.dart';

enum _TimeRange { today, week, month }

class AdminDashboardScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const AdminDashboardScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<AdminDashboardScreen> createState() => _AdminDashboardScreenState();
}

class _AdminDashboardScreenState extends State<AdminDashboardScreen> {
  Map<String, dynamic>? _response;
  bool _isLoading = false;
  String? _error;

  int? _expandedVaultSafeBoxId;
  int? _pressedVaultSafeBoxId;

  _TimeRange _timeRange = _TimeRange.week;

  double _uiScale(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1200) return 1.20;
    if (width >= 900) return 1.12;
    if (width >= 600) return 1.04;
    return 1.0;
  }

  double _s(double value) => value * _uiScale(context);

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;

  @override
  void initState() {
    super.initState();
    _currencyFormat = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimals,
    );
    _weightFormat = NumberFormat('#,##0.000');
    _loadData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);
    final symbol = settings.currencySymbol;
    final decimals = settings.decimalPlaces;

    if (symbol != _currencySymbol || decimals != _currencyDecimals) {
      setState(() {
        _currencySymbol = symbol;
        _currencyDecimals = decimals;
        _currencyFormat = NumberFormat.currency(
          locale: widget.isArabic ? 'ar' : 'en',
          symbol: _currencySymbol,
          decimalDigits: _currencyDecimals,
        );
      });
    }
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.api.getAdminDashboard();
      if (!mounted) return;
      setState(() => _response = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  double _asDouble(dynamic value) => value is num ? value.toDouble() : 0.0;

  double? _asDoubleOrNull(dynamic value) =>
      value is num ? value.toDouble() : null;

  int _asInt(dynamic value) =>
      value is int ? value : (value is num ? value.toInt() : 0);

  String _formatCurrency(num value) => _currencyFormat.format(value);
  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;

    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        body: SafeArea(
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? _buildErrorState()
              : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildErrorState() {
    final isArabic = widget.isArabic;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: _s(52), color: Colors.red.shade400),
          SizedBox(height: _s(12)),
          Text(
            isArabic ? 'تعذّر تحميل البيانات' : 'Failed to load data',
            style: TextStyle(fontSize: _s(18), fontWeight: FontWeight.bold),
          ),
          SizedBox(height: _s(8)),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: _s(24)),
            child: Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: _s(12)),
            ),
          ),
          SizedBox(height: _s(16)),
          ElevatedButton.icon(
            onPressed: _loadData,
            icon: const Icon(Icons.refresh),
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final globalSnapshot =
        (_response?['global_snapshot'] as Map<String, dynamic>?) ?? {};
    final kpis = (_response?['kpis'] as Map<String, dynamic>?) ?? {};
    final alerts = (_response?['alerts'] as Map<String, dynamic>?) ?? {};
    final valuation = (_response?['valuation'] as Map<String, dynamic>?) ?? {};
    final liquidity = (_response?['liquidity'] as Map<String, dynamic>?) ?? {};
    final safeBoxes = (_response?['safe_boxes'] as List?) ?? [];
    final sensitiveOps = (_response?['sensitive_operations'] as List?) ?? [];
    final series = (_response?['series'] as Map<String, dynamic>?) ?? {};

    final goldByKarat = (kpis['gold_by_karat'] as Map<String, dynamic>?) ?? {};

    return RefreshIndicator(
      onRefresh: _loadData,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          // === 1. The Global Snapshot Header ===
          SliverToBoxAdapter(
            child: _buildGlobalSnapshotHeader(
              globalSnapshot,
              valuation,
              series,
            ),
          ),

          // === 1.5 Critical Alert Bar (Smart Alerts) ===
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(_s(16), 0, _s(16), _s(10)),
              child: _buildCriticalAlertBar(alerts),
            ),
          ),

          // === 2. Audit Zone (Dynamic Alerts) ===
          SliverToBoxAdapter(child: _buildAuditZone(alerts)),

          // === 2.5 Time Range Selector ===
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(_s(16), _s(8), _s(16), 0),
              child: _buildRangeSelector(),
            ),
          ),

          // === 3. Core KPIs Grid (Responsive) ===
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(_s(16)),
              child: _buildKpiGrid(
                kpis: kpis,
                series: series,
                goldByKarat: goldByKarat,
                liquidity: liquidity,
              ),
            ),
          ),

          // === 4. Vaults & Custody (Horizontal List) ===
          SliverToBoxAdapter(child: _buildVaultsSection(safeBoxes)),

          // === 5. Sensitive Operations Feed ===
          SliverToBoxAdapter(
            child: _buildSensitiveOperationsSection(sensitiveOps),
          ),

          SliverToBoxAdapter(child: SizedBox(height: _s(24))),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 1. GLOBAL SNAPSHOT HEADER
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildGlobalSnapshotHeader(
    Map<String, dynamic> snapshot,
    Map<String, dynamic> valuation,
    Map<String, dynamic> series,
  ) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final netPosition = _asDouble(snapshot['net_financial_position']);
    final goldPrice = _asDouble(snapshot['gold_price_24k']);
    final goldChange = snapshot['gold_price_change_pct'];

    final changeValue = goldChange is num ? goldChange.toDouble() : null;
    final isPositive = (changeValue ?? 0) >= 0;

    final goldPriceSeries = _extractSeries(series, const [
      'gold_price',
      'gold_price_24k',
      'gold_price_series',
      'gold_price_trend',
    ]);

    final isCompact = MediaQuery.of(context).size.width < 700;

    return Container(
      padding: EdgeInsets.fromLTRB(_s(16), _s(12), _s(16), _s(16)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.primaryGold.withValues(alpha: 0.15),
            theme.scaffoldBackgroundColor,
          ],
        ),
      ),
      child: Column(
        children: [
          // Top Row: Title + Actions
          Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_forward_ios, size: _s(20)),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const Spacer(),
              Text(
                isArabic ? 'لوحة تحكم المدير' : 'Admin Dashboard',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              IconButton(
                icon: Icon(Icons.notifications_outlined, size: _s(22)),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SystemAlertsScreen(
                        api: widget.api,
                        isArabic: widget.isArabic,
                      ),
                    ),
                  );
                  _loadData();
                },
              ),
              IconButton(
                icon: Icon(Icons.refresh, size: _s(22)),
                onPressed: _isLoading ? null : _loadData,
              ),
            ],
          ),
          SizedBox(height: _s(16)),

          // Main Snapshot Row
          if (isCompact)
            Column(
              children: [
                _buildNetPositionCard(theme, isArabic, netPosition),
                SizedBox(height: _s(12)),
                _buildGoldPriceCard(
                  theme,
                  isPositive,
                  goldPrice,
                  changeValue,
                  goldPriceSeries: goldPriceSeries,
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  flex: 3,
                  child: _buildNetPositionCard(theme, isArabic, netPosition),
                ),
                SizedBox(width: _s(12)),
                Expanded(
                  flex: 2,
                  child: _buildGoldPriceCard(
                    theme,
                    isPositive,
                    goldPrice,
                    changeValue,
                    goldPriceSeries: goldPriceSeries,
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildRangeSelector() {
    final isArabic = widget.isArabic;

    return Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: _s(8),
            runSpacing: _s(8),
            children: [
              ChoiceChip(
                label: Text(isArabic ? 'اليوم' : 'Today'),
                selected: _timeRange == _TimeRange.today,
                onSelected: (_) =>
                    setState(() => _timeRange = _TimeRange.today),
              ),
              ChoiceChip(
                label: Text(isArabic ? '٧ أيام' : '7D'),
                selected: _timeRange == _TimeRange.week,
                onSelected: (_) => setState(() => _timeRange = _TimeRange.week),
              ),
              ChoiceChip(
                label: Text(isArabic ? '٣٠ يوم' : '30D'),
                selected: _timeRange == _TimeRange.month,
                onSelected: (_) =>
                    setState(() => _timeRange = _TimeRange.month),
              ),
            ],
          ),
        ),
        TextButton.icon(
          onPressed: _isLoading ? null : _loadData,
          icon: Icon(Icons.refresh, size: _s(20)),
          label: Text(isArabic ? 'تحديث' : 'Refresh'),
        ),
      ],
    );
  }

  Widget _buildKpiGrid({
    required Map<String, dynamic> kpis,
    required Map<String, dynamic> series,
    required Map<String, dynamic> goldByKarat,
    required Map<String, dynamic> liquidity,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        int crossAxisCount;
        double ratio;

        if (width >= 1200) {
          crossAxisCount = 4;
          ratio = 1.55;
        } else if (width >= 900) {
          crossAxisCount = 3;
          ratio = 1.45;
        } else if (width >= 600) {
          crossAxisCount = 2;
          ratio = 1.35;
        } else {
          crossAxisCount = 1;
          ratio = 1.25;
        }

        return GridView.count(
          crossAxisCount: crossAxisCount,
          childAspectRatio: ratio,
          mainAxisSpacing: _s(12),
          crossAxisSpacing: _s(12),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            _buildSalesVsPurchasesCard(kpis, series),
            _buildKaratDistributionCard(goldByKarat),
            _buildLiquidityBreakdownCard(liquidity),
            _buildTodayProfitCard(kpis),
          ],
        );
      },
    );
  }

  Widget _buildNetPositionCard(
    ThemeData theme,
    bool isArabic,
    double netPosition,
  ) {
    return Container(
      padding: EdgeInsets.all(_s(16)),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: AppColors.primaryGold.withValues(alpha: 0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.account_balance,
                color: AppColors.primaryGold,
                size: _s(20),
              ),
              SizedBox(width: _s(6)),
              Text(
                isArabic ? 'صافي المركز المالي' : 'Net Position',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                  fontSize: _s(12),
                ),
              ),
            ],
          ),
          SizedBox(height: _s(8)),
          Text(
            _formatCurrency(netPosition),
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: AppColors.primaryGold,
              fontSize: _s(22),
            ),
          ),
          Text(
            isArabic ? '(نقد + قيمة الذهب)' : '(Cash + Gold Value)',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.hintColor,
              fontSize: _s(11),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGoldPriceCard(
    ThemeData theme,
    bool isPositive,
    double goldPrice,
    double? changeValue, {
    List<double>? goldPriceSeries,
  }) {
    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => GoldPriceHistoryReportScreen(
              api: widget.api,
              isArabic: widget.isArabic,
            ),
          ),
        );
      },
      child: Container(
        padding: EdgeInsets.all(_s(16)),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: (isPositive ? Colors.green : Colors.red).withValues(
              alpha: 0.3,
            ),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.show_chart,
                  color: isPositive ? Colors.green : Colors.red,
                  size: _s(20),
                ),
                SizedBox(width: _s(6)),
                Text(
                  '24K',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            SizedBox(height: _s(10)),
            Text(
              goldPrice > 0
                  ? '${goldPrice.toStringAsFixed(0)} $_currencySymbol'
                  : '-',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: _s(20),
              ),
            ),
            if (changeValue != null)
              Row(
                children: [
                  Icon(
                    isPositive ? Icons.arrow_upward : Icons.arrow_downward,
                    size: _s(14),
                    color: isPositive ? Colors.green : Colors.red,
                  ),
                  Text(
                    '${changeValue.abs().toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: _s(12),
                      fontWeight: FontWeight.bold,
                      color: isPositive ? Colors.green : Colors.red,
                    ),
                  ),
                ],
              ),
            if ((goldPriceSeries ?? const []).isNotEmpty) ...[
              SizedBox(height: _s(10)),
              SizedBox(
                height: _s(44),
                child: LineChart(
                  LineChartData(
                    gridData: const FlGridData(show: false),
                    titlesData: const FlTitlesData(show: false),
                    borderData: FlBorderData(show: false),
                    lineTouchData: const LineTouchData(enabled: false),
                    lineBarsData: [
                      LineChartBarData(
                        spots: _toSpots(
                          goldPriceSeries!.take(24).toList(),
                          goldPriceSeries.take(24).length,
                        ),
                        isCurved: true,
                        color: isPositive ? Colors.green : Colors.red,
                        barWidth: _s(2),
                        dotData: const FlDotData(show: false),
                        belowBarData: BarAreaData(
                          show: true,
                          color: (isPositive ? Colors.green : Colors.red)
                              .withValues(alpha: 0.12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            SizedBox(height: _s(8)),
            Text(
              widget.isArabic ? 'اضغط للتفاصيل' : 'Tap for details',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
                fontSize: _s(11),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 2. AUDIT ZONE (Dynamic Alerts)
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildAuditZone(Map<String, dynamic> alerts) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final criticalCount = _asInt(alerts['critical_unreviewed_count']);
    final unpostedCount = _asInt(alerts['unposted_invoices_count']);
    final lastShift = alerts['last_shift_closing'] as Map<String, dynamic>?;

    final cashDiff = _asDouble(lastShift?['cash_difference']);
    final goldDiff = _asDouble(lastShift?['gold_pure_24k_difference']);

    List<_AlertItem> alertItems = [];

    if (criticalCount > 0) {
      alertItems.add(
        _AlertItem(
          icon: Icons.warning_amber_rounded,
          color: Colors.red,
          text: isArabic
              ? '$criticalCount تنبيهات حرجة بانتظار المراجعة'
              : '$criticalCount critical alerts pending',
        ),
      );
    }

    if (cashDiff.abs() > 0.01) {
      alertItems.add(
        _AlertItem(
          icon: Icons.account_balance_wallet,
          color: Colors.orange,
          text: isArabic
              ? 'فرق نقدي (${_formatCurrency(cashDiff)}) في آخر إغلاق'
              : 'Cash difference (${_formatCurrency(cashDiff)}) in last closing',
        ),
      );
    }

    if (goldDiff.abs() > 0.001) {
      alertItems.add(
        _AlertItem(
          icon: Icons.auto_awesome,
          color: Colors.orange,
          text: isArabic
              ? 'فرق ذهب (${_formatWeight(goldDiff)}) في آخر إغلاق'
              : 'Gold difference (${_formatWeight(goldDiff)}) in last closing',
        ),
      );
    }

    if (unpostedCount > 0) {
      alertItems.add(
        _AlertItem(
          icon: Icons.pending_actions,
          color: Colors.blue,
          text: isArabic
              ? '$unpostedCount فاتورة بانتظار الترحيل'
              : '$unpostedCount invoices pending posting',
        ),
      );
    }

    if (alertItems.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      margin: EdgeInsets.symmetric(horizontal: _s(16)),
      padding: EdgeInsets.all(_s(12)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.red.shade50, Colors.orange.shade50],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.red.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.security, color: Colors.red.shade700, size: _s(22)),
              SizedBox(width: _s(8)),
              Text(
                isArabic ? 'الرقابة والمطابقة' : 'Audit Zone',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: Colors.red.shade700,
                ),
              ),
            ],
          ),
          SizedBox(height: _s(8)),
          ...alertItems.map(
            (alert) => Padding(
              padding: EdgeInsets.only(bottom: _s(6)),
              child: Row(
                children: [
                  Icon(alert.icon, color: alert.color, size: _s(18)),
                  SizedBox(width: _s(8)),
                  Expanded(
                    child: Text(
                      alert.text,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: alert.color,
                        fontWeight: FontWeight.w500,
                        fontSize: _s(12),
                      ),
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

  Widget _buildCriticalAlertBar(Map<String, dynamic> alerts) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final items = (alerts['critical_bar'] as List?) ?? [];
    if (items.isEmpty) return const SizedBox.shrink();

    Color borderColor = Colors.orange.shade300;
    Color background = Colors.orange.shade50;

    final hasCritical = items.any((e) {
      if (e is Map) {
        return (e['severity']?.toString().toLowerCase() ?? '') == 'critical';
      }
      return false;
    });

    if (hasCritical) {
      borderColor = Colors.red.shade300;
      background = Colors.red.shade50;
    }

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                SystemAlertsScreen(api: widget.api, isArabic: widget.isArabic),
          ),
        );
      },
      child: Container(
        padding: EdgeInsets.all(_s(12)),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  hasCritical ? Icons.report : Icons.warning_amber_rounded,
                  color: hasCritical
                      ? Colors.red.shade700
                      : Colors.orange.shade800,
                  size: _s(20),
                ),
                SizedBox(width: _s(8)),
                Expanded(
                  child: Text(
                    isArabic ? 'تنبيهات ذكية' : 'Smart Alerts',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: hasCritical
                          ? Colors.red.shade700
                          : Colors.orange.shade800,
                    ),
                  ),
                ),
                Icon(
                  isArabic ? Icons.chevron_left : Icons.chevron_right,
                  color: theme.hintColor,
                ),
              ],
            ),
            SizedBox(height: _s(8)),
            ...items.take(3).map((raw) {
              final item = raw is Map ? raw : <String, dynamic>{};
              final severity =
                  (item['severity']?.toString().toLowerCase() ?? 'warning');
              final msg =
                  (isArabic
                      ? (item['message_ar']?.toString())
                      : (item['message_en']?.toString())) ??
                  (item['message']?.toString() ?? '');
              return Padding(
                padding: EdgeInsets.only(bottom: _s(6)),
                child: _buildCriticalAlertBarRow(severity: severity, text: msg),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildCriticalAlertBarRow({
    required String severity,
    required String text,
  }) {
    final theme = Theme.of(context);

    final isCritical = severity == 'critical';
    final color = isCritical ? Colors.red : Colors.orange;
    final icon = isCritical ? Icons.error_outline : Icons.warning_amber_rounded;

    return Row(
      children: [
        Icon(icon, color: color, size: _s(18)),
        SizedBox(width: _s(8)),
        Expanded(
          child: Text(
            text,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: color.shade700,
              fontWeight: FontWeight.w600,
              fontSize: _s(12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTrendPill({
    required double? value,
    required Color positiveColor,
    required Color negativeColor,
    required String label,
  }) {
    final theme = Theme.of(context);
    final hasValue = value != null;
    final isUp = hasValue ? (value >= 0) : true;
    final color = hasValue
        ? (isUp ? positiveColor : negativeColor)
        : Colors.blueGrey;
    final icon = hasValue
        ? (isUp ? Icons.trending_up : Icons.trending_down)
        : Icons.remove;

    return Container(
      padding: EdgeInsets.symmetric(horizontal: _s(8), vertical: _s(3)),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(_s(999)),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: _s(14), color: color),
          SizedBox(width: _s(4)),
          Text(
            hasValue ? '${value.abs().toStringAsFixed(1)}% $label' : '— $label',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: color,
              fontSize: _s(10.5),
            ),
          ),
        ],
      ),
    );
  }

  List<double> _seriesFromRows(dynamic rows, {required String field}) {
    if (rows is! List) return const [];
    final out = <double>[];
    for (final r in rows) {
      if (r is Map) {
        final v = r[field];
        if (v is num) out.add(v.toDouble());
      }
    }
    return out;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 3. CORE KPI CARDS
  // ══════════════════════════════════════════════════════════════════════════

  // Sales vs Purchases Sparkline Card
  Widget _buildSalesVsPurchasesCard(
    Map<String, dynamic> kpis,
    Map<String, dynamic> series,
  ) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final salesToday = (kpis['sales_today'] as Map<String, dynamic>?) ?? {};
    final purchasesToday =
        (kpis['purchases_today'] as Map<String, dynamic>?) ?? {};
    final salesWeight = _asDouble(salesToday['net_weight']);
    final purchasesWeight = _asDouble(purchasesToday['net_weight']);

    final salesTrendPct = _asDoubleOrNull(
      salesToday['change_pct_weight'] ?? salesToday['change_pct'],
    );
    final purchasesTrendPct = _asDoubleOrNull(
      purchasesToday['change_pct_weight'] ?? purchasesToday['change_pct'],
    );

    final netFlow = salesWeight - purchasesWeight;

    var salesSeries = _extractSeries(series, const [
      'sales',
      'sales_series',
      'sales_weights',
      'sales_values',
    ]);
    var purchasesSeries = _extractSeries(series, const [
      'purchases',
      'purchases_series',
      'purchases_weights',
      'purchases_values',
    ]);

    // Backend canonical shape: series.last_7_days_sales/purchases is a list of rows
    if (salesSeries.isEmpty) {
      salesSeries = _seriesFromRows(
        series['last_7_days_sales'],
        field: 'net_weight',
      );
    }
    if (purchasesSeries.isEmpty) {
      purchasesSeries = _seriesFromRows(
        series['last_7_days_purchases'],
        field: 'net_weight',
      );
    }

    return _buildKpiCardWrapper(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => SalesVsPurchasesTrendReportScreen(
              api: widget.api,
              isArabic: widget.isArabic,
            ),
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.swap_horiz, color: Colors.blue, size: _s(20)),
              SizedBox(width: _s(6)),
              Expanded(
                child: Text(
                  isArabic ? 'المبيعات vs المشتريات' : 'Sales vs Purchases',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontSize: _s(12),
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          SizedBox(height: _s(12)),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isArabic ? 'مبيعات' : 'Sales',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                      fontSize: _s(11),
                    ),
                  ),
                  Text(
                    _formatWeight(salesWeight),
                    style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: _s(14),
                    ),
                  ),
                  SizedBox(height: _s(4)),
                  _buildTrendPill(
                    value: salesTrendPct,
                    positiveColor: Colors.green,
                    negativeColor: Colors.red,
                    label: isArabic ? 'عن أمس' : 'vs yesterday',
                  ),
                ],
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    isArabic ? 'مشتريات' : 'Purchases',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                      fontSize: _s(11),
                    ),
                  ),
                  Text(
                    _formatWeight(purchasesWeight),
                    style: TextStyle(
                      color: Colors.orange,
                      fontWeight: FontWeight.bold,
                      fontSize: _s(14),
                    ),
                  ),
                  SizedBox(height: _s(4)),
                  _buildTrendPill(
                    value: purchasesTrendPct,
                    positiveColor: Colors.orange,
                    negativeColor: Colors.blueGrey,
                    label: isArabic ? 'عن أمس' : 'vs yesterday',
                  ),
                ],
              ),
            ],
          ),
          SizedBox(height: _s(8)),
          Container(
            padding: EdgeInsets.symmetric(horizontal: _s(8), vertical: _s(4)),
            decoration: BoxDecoration(
              color: (netFlow >= 0 ? Colors.red : Colors.green).withValues(
                alpha: 0.1,
              ),
              borderRadius: BorderRadius.circular(_s(6)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  netFlow >= 0 ? Icons.arrow_upward : Icons.arrow_downward,
                  size: _s(14),
                  color: netFlow >= 0 ? Colors.red : Colors.green,
                ),
                SizedBox(width: _s(4)),
                Text(
                  '${isArabic ? "صافي التدفق: " : "Net: "}${_formatWeight(netFlow.abs())}',
                  style: TextStyle(
                    fontSize: _s(11),
                    fontWeight: FontWeight.bold,
                    color: netFlow >= 0 ? Colors.red : Colors.green,
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: _s(10)),
          Expanded(
            child: _buildSalesVsPurchasesSparkline(
              salesSeries: salesSeries,
              purchasesSeries: purchasesSeries,
            ),
          ),
        ],
      ),
    );
  }

  List<double> _extractSeries(
    Map<String, dynamic> series,
    List<String> directKeys,
  ) {
    // 1) direct keys
    for (final key in directKeys) {
      final list = _castNumberList(series[key]);
      if (list.isNotEmpty) return list;
    }

    // 2) common composite container
    final composite = series['sales_vs_purchases'];
    if (composite is Map<String, dynamic>) {
      final list = _extractSeries(composite, directKeys);
      if (list.isNotEmpty) return list;
    }

    // 3) range keyed containers
    for (final rangeKey in _rangeKeyCandidates(_timeRange)) {
      final ranged = series[rangeKey];
      if (ranged is Map<String, dynamic>) {
        final list = _extractSeries(ranged, directKeys);
        if (list.isNotEmpty) return list;
      }
    }

    return const [];
  }

  List<String> _rangeKeyCandidates(_TimeRange range) {
    switch (range) {
      case _TimeRange.today:
        return const ['today', '1d', 'day', 'last_1_day', 'last_24_hours'];
      case _TimeRange.week:
        return const ['week', '7d', 'last_7_days', 'last7', 'last_week'];
      case _TimeRange.month:
        return const ['month', '30d', 'last_30_days', 'last30', 'last_month'];
    }
  }

  List<double> _castNumberList(dynamic value) {
    if (value is List) {
      return value
          .map((e) => e is num ? e.toDouble() : null)
          .whereType<double>()
          .toList();
    }
    return const [];
  }

  Widget _buildSalesVsPurchasesSparkline({
    required List<double> salesSeries,
    required List<double> purchasesSeries,
  }) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    if (salesSeries.isEmpty && purchasesSeries.isEmpty) {
      return Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceVariant.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          isArabic ? 'لا توجد بيانات للرسم' : 'No chart data',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.hintColor,
            fontSize: _s(11),
          ),
        ),
      );
    }

    final maxLength = salesSeries.length > purchasesSeries.length
        ? salesSeries.length
        : purchasesSeries.length;
    final spotsSales = _toSpots(salesSeries, maxLength);
    final spotsPurchases = _toSpots(purchasesSeries, maxLength);

    final values = [...salesSeries, ...purchasesSeries];
    final minY = values.isEmpty ? 0.0 : values.reduce((a, b) => a < b ? a : b);
    final maxY = values.isEmpty ? 1.0 : values.reduce((a, b) => a > b ? a : b);
    final padding = (maxY - minY).abs() * 0.2;

    return ClipRRect(
      borderRadius: BorderRadius.circular(_s(8)),
      child: LineChart(
        LineChartData(
          gridData: const FlGridData(show: false),
          titlesData: const FlTitlesData(show: false),
          borderData: FlBorderData(show: false),
          lineTouchData: const LineTouchData(enabled: false),
          minX: 0,
          maxX: maxLength > 0 ? (maxLength - 1).toDouble() : 1,
          minY: minY - padding,
          maxY: maxY + padding,
          lineBarsData: [
            if (spotsSales.isNotEmpty)
              LineChartBarData(
                spots: spotsSales,
                isCurved: true,
                color: Colors.green,
                barWidth: _s(2),
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.green.withValues(alpha: 0.12),
                ),
              ),
            if (spotsPurchases.isNotEmpty)
              LineChartBarData(
                spots: spotsPurchases,
                isCurved: true,
                color: Colors.orange,
                barWidth: _s(2),
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: Colors.orange.withValues(alpha: 0.12),
                ),
              ),
          ],
        ),
      ),
    );
  }

  List<FlSpot> _toSpots(List<double> series, int length) {
    if (series.isEmpty) return const [];
    final spots = <FlSpot>[];
    for (var i = 0; i < length; i++) {
      final value = i < series.length ? series[i] : series.last;
      spots.add(FlSpot(i.toDouble(), value));
    }
    return spots;
  }

  // Karat Distribution Donut Card
  Widget _buildKaratDistributionCard(Map<String, dynamic> goldByKarat) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final k18 = _asDouble(goldByKarat['18k']);
    final k21 = _asDouble(goldByKarat['21k']);
    final k22 = _asDouble(goldByKarat['22k']);
    final k24 = _asDouble(goldByKarat['24k']);
    final total = k18 + k21 + k22 + k24;

    return _buildKpiCardWrapper(
      onTap: () {
        // Navigate to inventory
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pie_chart, color: AppColors.primaryGold, size: _s(20)),
              SizedBox(width: _s(6)),
              Text(
                isArabic ? 'توزيع العيارات' : 'Karat Mix',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: _s(12),
                ),
              ),
            ],
          ),
          SizedBox(height: _s(12)),
          if (total == 0)
            Center(
              child: Text(
                isArabic ? 'لا يوجد ذهب' : 'No gold',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.hintColor,
                ),
              ),
            )
          else
            Row(
              children: [
                // Mini Donut Chart
                SizedBox(
                  width: _s(70),
                  height: _s(70),
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 1,
                      centerSpaceRadius: _s(18),
                      sections: [
                        PieChartSectionData(
                          value: k24,
                          color: AppColors.primaryGold,
                          radius: _s(15),
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: k22,
                          color: Colors.amber.shade600,
                          radius: _s(15),
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: k21,
                          color: Colors.orange.shade600,
                          radius: _s(15),
                          showTitle: false,
                        ),
                        PieChartSectionData(
                          value: k18,
                          color: Colors.deepOrange.shade400,
                          radius: _s(15),
                          showTitle: false,
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: _s(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildKaratLegendItem(
                        label: '24K',
                        value: k24,
                        color: AppColors.primaryGold,
                        total: total,
                      ),
                      _buildKaratLegendItem(
                        label: '22K',
                        value: k22,
                        color: Colors.amber.shade600,
                        total: total,
                      ),
                      _buildKaratLegendItem(
                        label: '21K',
                        value: k21,
                        color: Colors.orange.shade600,
                        total: total,
                      ),
                      _buildKaratLegendItem(
                        label: '18K',
                        value: k18,
                        color: Colors.deepOrange.shade400,
                        total: total,
                      ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }

  Widget _buildKaratLegendItem({
    required String label,
    required double value,
    required Color color,
    required double total,
  }) {
    final pct = total > 0 ? (value / total * 100).toStringAsFixed(0) : '0';
    return Padding(
      padding: EdgeInsets.only(bottom: _s(2)),
      child: Row(
        children: [
          Container(
            width: _s(9),
            height: _s(9),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          SizedBox(width: _s(6)),
          Expanded(
            child: Text(
              '$label: ${_formatWeight(value)} • $pct%',
              style: TextStyle(fontSize: _s(11)),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // Liquidity Breakdown Card
  Widget _buildLiquidityBreakdownCard(Map<String, dynamic> liquidity) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final cashInHand = _asDouble(liquidity['cash_in_hand']);
    final cashInBanks = _asDouble(liquidity['cash_in_banks']);
    final receivables = _asDouble(liquidity['receivables']);
    final total = cashInHand + cashInBanks + receivables;

    return _buildKpiCardWrapper(
      onTap: () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.water_drop, color: Colors.blue, size: _s(20)),
              SizedBox(width: _s(6)),
              Text(
                isArabic ? 'مركز السيولة' : 'Liquidity',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: _s(12),
                ),
              ),
            ],
          ),
          SizedBox(height: _s(12)),
          _buildLiquidityRow(
            isArabic ? 'نقدية' : 'Cash',
            cashInHand,
            Colors.green,
            total,
          ),
          SizedBox(height: _s(4)),
          _buildLiquidityRow(
            isArabic ? 'بنوك' : 'Banks',
            cashInBanks,
            Colors.blue,
            total,
          ),
          SizedBox(height: _s(4)),
          _buildLiquidityRow(
            isArabic ? 'ذمم' : 'Receiv.',
            receivables,
            Colors.orange,
            total,
          ),
        ],
      ),
    );
  }

  Widget _buildLiquidityRow(
    String label,
    double value,
    Color color,
    double total,
  ) {
    final pct = total > 0 ? value / total : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: TextStyle(fontSize: _s(11))),
            Text(
              _formatCurrency(value),
              style: TextStyle(fontSize: _s(11), fontWeight: FontWeight.bold),
            ),
          ],
        ),
        SizedBox(height: _s(2)),
        ClipRRect(
          borderRadius: BorderRadius.circular(_s(2)),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: _s(4),
            backgroundColor: color.withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  // Today's Profit Card
  Widget _buildTodayProfitCard(Map<String, dynamic> kpis) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final todayProfit = _asDouble(kpis['today_profit']);
    final profitMargin = kpis['today_profit_margin_pct'];
    final marginValue = profitMargin is num ? profitMargin.toDouble() : null;

    final isPositive = todayProfit >= 0;

    return _buildKpiCardWrapper(
      onTap: () {},
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.trending_up,
                color: isPositive ? Colors.green : Colors.red,
                size: _s(20),
              ),
              SizedBox(width: _s(6)),
              Text(
                isArabic ? 'هامش الربح اليوم' : 'Today Profit',
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: _s(12),
                ),
              ),
            ],
          ),
          SizedBox(height: _s(12)),
          Text(
            _formatCurrency(todayProfit),
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: isPositive ? Colors.green : Colors.red,
              fontSize: _s(20),
            ),
          ),
          if (marginValue != null)
            Container(
              margin: EdgeInsets.only(top: _s(4)),
              padding: EdgeInsets.symmetric(horizontal: _s(6), vertical: _s(2)),
              decoration: BoxDecoration(
                color: (isPositive ? Colors.green : Colors.red).withValues(
                  alpha: 0.1,
                ),
                borderRadius: BorderRadius.circular(_s(4)),
              ),
              child: Text(
                '${marginValue.toStringAsFixed(1)}% ${isArabic ? "هامش" : "margin"}',
                style: TextStyle(
                  fontSize: _s(11),
                  fontWeight: FontWeight.bold,
                  color: isPositive ? Colors.green : Colors.red,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildKpiCardWrapper({required Widget child, VoidCallback? onTap}) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: EdgeInsets.all(_s(12)),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.05),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 4. VAULTS & CUSTODY (Horizontal List)
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildVaultsSection(List<dynamic> safeBoxes) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    if (safeBoxes.isEmpty) return const SizedBox.shrink();

    final anyExpanded = _expandedVaultSafeBoxId != null;
    // Give cards enough vertical room to avoid RenderFlex overflow.
    final listHeight = anyExpanded ? _s(240) : _s(132);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _s(16)),
          child: Row(
            children: [
              Icon(
                Icons.inventory_2,
                color: theme.colorScheme.primary,
                size: _s(22),
              ),
              SizedBox(width: _s(8)),
              Text(
                isArabic ? 'توزيع العهد والخزائن' : 'Vaults & Custody',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SafeBoxesScreen(
                        api: widget.api,
                        isArabic: widget.isArabic,
                        balancesView: true,
                      ),
                    ),
                  );
                },
                child: Text(isArabic ? 'عرض الكل' : 'View all'),
              ),
            ],
          ),
        ),
        SizedBox(height: _s(12)),
        SizedBox(
          height: listHeight,
          child: AnimationLimiter(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(horizontal: _s(16)),
              itemCount: safeBoxes.length,
              itemBuilder: (context, index) {
                final sb = safeBoxes[index] as Map<String, dynamic>;
                final id = sb['id'];
                final sbId = id is int ? id : int.tryParse(id?.toString() ?? '');
                final heroTag = sbId != null ? 'vault_safe_box_$sbId' : 'vault_safe_box_$index';
                final isExpanded =
                    (sbId != null && sbId == _expandedVaultSafeBoxId);
                final isPressed =
                    (sbId != null && sbId == _pressedVaultSafeBoxId);

                final card = _buildVaultCard(
                  sb,
                  heroTag: heroTag,
                  isExpanded: isExpanded,
                  isPressed: isPressed,
                  onTap: () {
                    if (sbId == null) return;
                    setState(() {
                      _expandedVaultSafeBoxId = isExpanded ? null : sbId;
                    });
                  },
                  onOpenDetails: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => _SafeBoxHeroDetailsScreen(
                          api: widget.api,
                          isArabic: widget.isArabic,
                          safeBox: sb,
                          heroTag: heroTag,
                        ),
                      ),
                    );
                  },
                  onPressChanged: (pressed) {
                    if (sbId == null) return;
                    setState(() {
                      if (pressed) {
                        _pressedVaultSafeBoxId = sbId;
                      } else if (_pressedVaultSafeBoxId == sbId) {
                        _pressedVaultSafeBoxId = null;
                      }
                    });
                  },
                );

                return AnimationConfiguration.staggeredList(
                  position: index,
                  duration: const Duration(milliseconds: 420),
                  child: SlideAnimation(
                    verticalOffset: 18.0,
                    child: FadeInAnimation(child: card),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  double _sbWeight(Map<String, dynamic> sb, String key) {
    final wb = sb['weight_balance'];
    if (wb is Map) {
      final raw = wb[key];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '') ?? 0.0;
    }
    return 0.0;
  }

  Widget _buildVaultCard(
    Map<String, dynamic> sb, {
    required String heroTag,
    required bool isExpanded,
    required bool isPressed,
    required VoidCallback onTap,
    required VoidCallback onOpenDetails,
    required ValueChanged<bool> onPressChanged,
  }) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final name = sb['name'] ?? '-';
    final safeType = sb['safe_type'] ?? 'cash';
    final cashBalance = _asDouble(sb['balance_cash']);
    final goldBalance = _asDouble(sb['balance_gold_21k']);
    final hasActivity = sb['has_recent_activity'] == true;

    final w18 = _sbWeight(sb, '18k');
    final w21 = _sbWeight(sb, '21k');
    final w22 = _sbWeight(sb, '22k');
    final w24 = _sbWeight(sb, '24k');
    final totalMain = _asDouble(sb['total_weight_main_karat']);
    final hasWeightBreakdown = sb['weight_balance'] is Map;
    final mainKaratFromApi = _asInt(sb['main_karat']);
    final displayMainKarat = mainKaratFromApi > 0 ? mainKaratFromApi : 21;

    double totalMainFallback() {
      final mk = displayMainKarat <= 0 ? 21.0 : displayMainKarat.toDouble();
      return (w18 * (18.0 / mk)) + w21 + (w22 * (22.0 / mk)) + (w24 * (24.0 / mk));
    }

    final totalMainEffective = (totalMain > 0)
        ? totalMain
        : (hasWeightBreakdown ? totalMainFallback() : 0.0);

    Color mainKaratChipColor(int karat) {
      switch (karat) {
        case 18:
          return AppColors.karat18;
        case 21:
          return AppColors.karat21;
        case 22:
          return AppColors.karat22;
        case 24:
          return AppColors.karat24;
        default:
          return AppColors.primaryGold;
      }
    }

    IconData icon;
    Color color;
    String subtitle;
    double primaryValue;
    String Function(double) primaryFormatter;

    switch (safeType) {
      case 'gold':
        icon = Icons.auto_awesome;
        color = AppColors.primaryGold;
        // Always show the main-karat equivalent total for gold safes.
        primaryValue = (totalMainEffective > 0 ? totalMainEffective : goldBalance);
        primaryFormatter = _formatWeight;
        subtitle = isArabic ? 'ذهب' : 'Gold';
        break;
      case 'bank':
        icon = Icons.account_balance;
        color = Colors.blue;
        primaryValue = cashBalance;
        primaryFormatter = _formatCurrency;
        subtitle = isArabic ? 'بنك' : 'Bank';
        break;
      default:
        icon = Icons.account_balance_wallet;
        color = Colors.green;
        primaryValue = cashBalance;
        primaryFormatter = _formatCurrency;
        subtitle = isArabic ? 'نقد' : 'Cash';
    }

    final cardWidth = isExpanded ? _s(280) : _s(155);

    Widget buildDetailChip(String label, String value, {Color? chipColor}) {
      final c = chipColor ?? color;
      return Container(
        padding: EdgeInsets.symmetric(horizontal: _s(8), vertical: _s(5)),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(_s(10)),
          border: Border.all(color: c.withValues(alpha: 0.28)),
        ),
        child: Text(
          '$label: $value',
          style: theme.textTheme.bodySmall?.copyWith(
            fontSize: _s(11),
            fontWeight: FontWeight.w600,
            color: theme.brightness == Brightness.dark
                ? Colors.white
                : Colors.black87,
          ),
        ),
      );
    }

    final details = safeType == 'gold'
        ? (hasWeightBreakdown
            ? Wrap(
                spacing: _s(8),
                runSpacing: _s(8),
                children: [
                  buildDetailChip('24k', _formatWeight(w24), chipColor: AppColors.karat24),
                  buildDetailChip('22k', _formatWeight(w22), chipColor: AppColors.karat22),
                  buildDetailChip('21k', _formatWeight(w21), chipColor: AppColors.karat21),
                  buildDetailChip('18k', _formatWeight(w18), chipColor: AppColors.karat18),
                  if ((w18.abs() + w21.abs() + w22.abs() + w24.abs()) > 0)
                    buildDetailChip(
                      isArabic
                          ? 'إجمالي (محول لعيار $displayMainKarat)'
                          : 'Total (converted to ${displayMainKarat}k)',
                      _formatWeight(totalMainEffective),
                      chipColor: mainKaratChipColor(displayMainKarat),
                    ),
                ],
              )
            : Wrap(
                spacing: _s(8),
                runSpacing: _s(8),
                children: [
                  buildDetailChip('21k', _formatWeight(goldBalance), chipColor: AppColors.karat21),
                  buildDetailChip(
                    isArabic ? 'ملاحظة' : 'Note',
                    isArabic
                        ? 'تفصيل العيارات غير متوفر بعد'
                        : 'Karat breakdown not available yet',
                    chipColor: theme.hintColor,
                  ),
                ],
              ))
        : Wrap(
            spacing: _s(8),
            runSpacing: _s(8),
            children: [
              buildDetailChip(
                isArabic ? 'الرصيد' : 'Balance',
                _formatCurrency(cashBalance),
                chipColor: color,
              ),
            ],
          );

    final borderAccent = hasActivity ? Colors.green : theme.hintColor;
    final borderColor = borderAccent.withValues(alpha: hasActivity ? 0.55 : 0.25);
    final glowColor = (hasActivity ? Colors.green : color).withValues(
      alpha: isPressed ? 0.22 : (isExpanded ? 0.14 : 0.10),
    );
    final glassBase = theme.colorScheme.surface.withValues(
      alpha: theme.brightness == Brightness.dark ? 0.25 : 0.78,
    );

    final heroIconTag = '${heroTag}_icon';
    final heroNameTag = '${heroTag}_name';

    final cardBody = Material(
      color: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTapDown: (_) => onPressChanged(true),
            onTapCancel: () => onPressChanged(false),
            onTap: () {
              onPressChanged(false);
              onTap();
            },
            child: AnimatedScale(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              scale: isPressed ? 0.985 : 1.0,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                width: cardWidth,
                padding: EdgeInsets.all(_s(12)),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: borderColor,
                    width: isPressed ? 1.2 : 1.0,
                  ),
                  gradient: LinearGradient(
                    begin: AlignmentDirectional.topStart,
                    end: AlignmentDirectional.bottomEnd,
                    colors: [
                      glassBase.withValues(alpha: 0.88),
                      glassBase.withValues(alpha: 0.72),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: glowColor,
                      blurRadius: isPressed ? 18 : (isExpanded ? 16 : 12),
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    PositionedDirectional(
                      start: 0,
                      top: 0,
                      bottom: 0,
                      child: Container(
                        width: _s(4),
                        decoration: BoxDecoration(
                          color: color.withValues(
                            alpha: hasActivity ? 0.85 : 0.55,
                          ),
                          borderRadius: BorderRadiusDirectional.horizontal(
                            start: Radius.circular(_s(14)),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsetsDirectional.only(start: _s(6)),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Hero(
                                tag: heroIconTag,
                                createRectTween: (begin, end) =>
                                    MaterialRectArcTween(begin: begin, end: end),
                                child: Material(
                                  color: Colors.transparent,
                                  child: Icon(
                                    icon,
                                    color: color,
                                    size: _s(20),
                                  ),
                                ),
                              ),
                              SizedBox(width: _s(6)),
                              if (hasActivity)
                                Container(
                                  width: _s(9),
                                  height: _s(9),
                                  decoration: const BoxDecoration(
                                    color: Colors.green,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                              const Spacer(),
                              InkResponse(
                                onTap: () {
                                  onPressChanged(false);
                                  onOpenDetails();
                                },
                                radius: _s(18),
                                child: Icon(
                                  Icons.open_in_new,
                                  color: theme.hintColor,
                                  size: _s(18),
                                ),
                              ),
                              SizedBox(width: _s(6)),
                              AnimatedRotation(
                                turns: isExpanded ? 0.5 : 0.0,
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOutCubic,
                                child: Icon(
                                  Icons.expand_more,
                                  color: theme.hintColor,
                                  size: _s(18),
                                ),
                              ),
                            ],
                          ),
                          SizedBox(height: _s(8)),
                          Hero(
                            tag: heroNameTag,
                            createRectTween: (begin, end) =>
                                MaterialRectArcTween(begin: begin, end: end),
                            child: Material(
                              color: Colors.transparent,
                              child: Text(
                                name,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: FontWeight.w700,
                                  fontSize: _s(12.5),
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                          SizedBox(height: _s(2)),
                          Text(
                            subtitle,
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontSize: _s(11),
                              color: theme.hintColor,
                            ),
                          ),
                          if (!isExpanded) const Spacer(),
                          SizedBox(height: _s(10)),
                          _AnimatedValueText(
                            value: primaryValue,
                            formatter: primaryFormatter,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: color,
                              fontSize: _s(14),
                            ),
                          ),
                          AnimatedCrossFade(
                            firstChild: const SizedBox.shrink(),
                            secondChild: Padding(
                              padding: EdgeInsets.only(top: _s(12)),
                              child: details,
                            ),
                            crossFadeState: isExpanded
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            duration: const Duration(milliseconds: 240),
                            firstCurve: Curves.easeOut,
                            secondCurve: Curves.easeOutCubic,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    return Container(
      margin: EdgeInsetsDirectional.only(start: _s(12)),
      child: cardBody,
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 5. SENSITIVE OPERATIONS FEED
  // ══════════════════════════════════════════════════════════════════════════
  Widget _buildSensitiveOperationsSection(List<dynamic> operations) {
    final theme = Theme.of(context);
    final isArabic = widget.isArabic;

    final hasData = operations.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(height: _s(16)),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: _s(16)),
          child: Row(
            children: [
              Icon(Icons.history, color: Colors.purple, size: _s(22)),
              SizedBox(width: _s(8)),
              Text(
                isArabic ? 'العمليات الحساسة' : 'Audit Trail',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AuditLogScreen()),
                  );
                },
                child: Text(isArabic ? 'السجل' : 'Log'),
              ),
            ],
          ),
        ),
        SizedBox(height: _s(8)),
        if (!hasData)
          Container(
            margin: EdgeInsets.symmetric(horizontal: _s(16)),
            padding: EdgeInsets.all(_s(12)),
            decoration: BoxDecoration(
              color: Colors.purple.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.purple.withValues(alpha: 0.1)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.shield_outlined,
                  color: Colors.purple.shade300,
                  size: _s(22),
                ),
                SizedBox(width: _s(10)),
                Expanded(
                  child: Text(
                    isArabic
                        ? 'لا توجد عمليات حساسة للعرض حالياً'
                        : 'No sensitive operations to show',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.hintColor,
                      fontSize: _s(12),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const AuditLogScreen()),
                    );
                  },
                  child: Text(isArabic ? 'فتح السجل' : 'Open log'),
                ),
              ],
            ),
          )
        else
          ...operations.take(5).map((op) {
            final opMap = op as Map<String, dynamic>;
            final desc = opMap['description'] ?? '-';
            final user = opMap['user_name'] ?? '-';
            final timeAgo = opMap['time_ago'] ?? '';
            final entityNumber = opMap['entity_number'];

            return InkWell(
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const AuditLogScreen()),
                );
              },
              borderRadius: BorderRadius.circular(8),
              child: Container(
                margin: EdgeInsets.symmetric(
                  horizontal: _s(16),
                  vertical: _s(4),
                ),
                padding: EdgeInsets.all(_s(10)),
                decoration: BoxDecoration(
                  color: Colors.purple.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.purple.withValues(alpha: 0.1),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.security,
                      color: Colors.purple.shade300,
                      size: _s(18),
                    ),
                    SizedBox(width: _s(8)),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$desc ${entityNumber != null ? "#$entityNumber" : ""}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              fontWeight: FontWeight.w600,
                              fontSize: _s(12),
                            ),
                          ),
                          Text(
                            '$user • $timeAgo',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.hintColor,
                              fontSize: _s(11),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_left,
                      size: _s(20),
                      color: theme.hintColor,
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }
}

class _AlertItem {
  final IconData icon;
  final Color color;
  final String text;

  _AlertItem({required this.icon, required this.color, required this.text});
}

class _SafeBoxHeroDetailsScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final Map<String, dynamic> safeBox;
  final String heroTag;

  const _SafeBoxHeroDetailsScreen({
    required this.api,
    required this.isArabic,
    required this.safeBox,
    required this.heroTag,
  });

  @override
  State<_SafeBoxHeroDetailsScreen> createState() =>
      _SafeBoxHeroDetailsScreenState();
}

class _SafeBoxHeroDetailsScreenState extends State<_SafeBoxHeroDetailsScreen> {
  late Map<String, dynamic> _safeBox;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _safeBox = Map<String, dynamic>.from(widget.safeBox);
    // Fetch the latest balances immediately on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
    });
  }

  double _uiScale(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1200) return 1.20;
    if (width >= 900) return 1.12;
    if (width >= 600) return 1.04;
    return 1.0;
  }

  double _s(BuildContext context, double value) => value * _uiScale(context);

  double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  int _asInt(dynamic v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  double _sbWeight(Map<String, dynamic> sb, String key) {
    final wb = sb['weight_balance'];
    if (wb is Map) {
      final raw = wb[key];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '') ?? 0.0;
    }
    return 0.0;
  }

  int? _safeBoxIdFromMap(Map<String, dynamic> sb) {
    final id = sb['id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  Map<String, dynamic> _mergeFromSafeBoxModel(SafeBoxModel m) {
    final wb = m.weightBalance;
    return <String, dynamic>{
      'id': m.id,
      'name': m.name,
      'safe_type': m.safeType,
      'weight_balance': wb,
      'total_weight_main_karat': m.totalWeightMainKarat,
      'balance_cash': m.cashBalance,
      // Keep the dashboard convention.
      'balance_gold_21k': wb?['21k'] ?? 0.0,
      // Best-effort: keep existing signal if present.
      'has_recent_activity': _safeBox['has_recent_activity'] == true,
      // Use safe's karat when available.
      'main_karat': m.karat,
    };
  }

  Future<void> _refresh() async {
    final id = _safeBoxIdFromMap(_safeBox);
    if (id == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final model = await widget.api.getSafeBox(id, includeBalance: true);
      if (!mounted) return;
      setState(() {
        _safeBox = {
          ..._safeBox,
          ..._mergeFromSafeBoxModel(model),
        };
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _safeBox['name'] ?? '-';
    final safeType = _safeBox['safe_type'] ?? 'cash';
    final cashBalance = _asDouble(_safeBox['balance_cash']);
    final goldBalance = _asDouble(_safeBox['balance_gold_21k']);
    final hasActivity = _safeBox['has_recent_activity'] == true;

    final w18 = _sbWeight(_safeBox, '18k');
    final w21 = _sbWeight(_safeBox, '21k');
    final w22 = _sbWeight(_safeBox, '22k');
    final w24 = _sbWeight(_safeBox, '24k');
    final totalMain = _asDouble(_safeBox['total_weight_main_karat']);
    final mainKaratFromApi = _asInt(_safeBox['main_karat']);
    final displayMainKarat = mainKaratFromApi > 0 ? mainKaratFromApi : 21;

    IconData icon;
    Color color;
    String subtitle;

    switch (safeType) {
      case 'gold':
        icon = Icons.auto_awesome;
        color = AppColors.primaryGold;
        subtitle = widget.isArabic ? 'ذهب' : 'Gold';
        break;
      case 'bank':
        icon = Icons.account_balance;
        color = Colors.blue;
        subtitle = widget.isArabic ? 'بنك' : 'Bank';
        break;
      default:
        icon = Icons.account_balance_wallet;
        color = Colors.green;
        subtitle = widget.isArabic ? 'نقد' : 'Cash';
    }

    Widget buildDetailChip(String label, String value, {Color? chipColor}) {
      final c = chipColor ?? color;
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: _s(context, 10),
          vertical: _s(context, 6),
        ),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(_s(context, 12)),
          border: Border.all(color: c.withValues(alpha: 0.28)),
        ),
        child: Text(
          '$label: $value',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: _s(context, 12),
          ),
        ),
      );
    }

    final heroIconTag = '${widget.heroTag}_icon';
    final heroNameTag = '${widget.heroTag}_name';

    final headerCard = Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.all(_s(context, 14)),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(_s(context, 16)),
          border: Border.all(
            color: (hasActivity ? Colors.green : theme.hintColor)
                .withValues(alpha: 0.25),
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Hero(
                  tag: heroIconTag,
                  createRectTween: (begin, end) =>
                      MaterialRectArcTween(begin: begin, end: end),
                  child: Material(
                    color: Colors.transparent,
                    child: Icon(icon, color: color, size: _s(context, 26)),
                  ),
                ),
                SizedBox(width: _s(context, 10)),
                Expanded(
                  child: Hero(
                    tag: heroNameTag,
                    createRectTween: (begin, end) =>
                        MaterialRectArcTween(begin: begin, end: end),
                    child: Material(
                      color: Colors.transparent,
                      child: Text(
                        name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                if (hasActivity)
                  Container(
                    width: _s(context, 9),
                    height: _s(context, 9),
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            SizedBox(height: _s(context, 6)),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );

    final detailsContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null)
          Padding(
            padding: EdgeInsets.only(top: _s(context, 12)),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
            ),
          ),
        SizedBox(height: _s(context, 16)),
        Card(
          elevation: 0,
          color: theme.cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_s(context, 16)),
            side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: EdgeInsets.all(_s(context, 14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.isArabic ? 'أرصدة مباشرة' : 'Live balances',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    if (_loading)
                      SizedBox(
                        width: _s(context, 18),
                        height: _s(context, 18),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                SizedBox(height: _s(context, 10)),
                if (safeType == 'gold')
                  Wrap(
                    spacing: _s(context, 10),
                    runSpacing: _s(context, 10),
                    children: [
                      buildDetailChip('24k', _weightFmt(w24)),
                      buildDetailChip('22k', _weightFmt(w22)),
                      buildDetailChip('21k', _weightFmt(w21)),
                      buildDetailChip('18k', _weightFmt(w18)),
                      buildDetailChip(
                        widget.isArabic
                            ? 'إجمالي (محول لعيار $displayMainKarat)'
                            : 'Total (converted to ${displayMainKarat}k)',
                        _weightFmt(totalMain > 0 ? totalMain : goldBalance),
                        chipColor: AppColors.primaryGold,
                      ),
                    ],
                  )
                else
                  Wrap(
                    spacing: _s(context, 10),
                    runSpacing: _s(context, 10),
                    children: [
                      buildDetailChip(
                        widget.isArabic ? 'الرصيد' : 'Balance',
                        _currencyFmt(cashBalance),
                        chipColor: color,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'تفاصيل الخزنة' : 'Safe Box Details'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SafeBoxesScreen(
                    api: widget.api,
                    isArabic: widget.isArabic,
                    balancesView: true,
                  ),
                ),
              );
            },
            child: Text(widget.isArabic ? 'عرض الكل' : 'View all'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.all(_s(context, 16)),
          children: [
            headerCard,
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              builder: (context, v, child) {
                return Opacity(
                  opacity: v,
                  child: Transform.translate(
                    offset: Offset(0, (1 - v) * 10),
                    child: child,
                  ),
                );
              },
              child: detailsContent,
            ),
          ],
        ),
      ),
    );
  }

  String _weightFmt(double v) {
    final f = NumberFormat('#,##0.000');
    return '${f.format(v)} g';
  }

  String _currencyFmt(double v) {
    final f = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: '',
      decimalDigits: 2,
    );
    final s = f.format(v).trim();
    return widget.isArabic ? '$s ر.س' : '$s SAR';
  }
}

class _AnimatedValueText extends StatefulWidget {
  final double value;
  final String Function(double) formatter;
  final TextStyle? style;

  const _AnimatedValueText({
    required this.value,
    required this.formatter,
    this.style,
  });

  @override
  State<_AnimatedValueText> createState() => _AnimatedValueTextState();
}

class _AnimatedValueTextState extends State<_AnimatedValueText> {
  late double _from;
  late double _to;

  @override
  void initState() {
    super.initState();
    _from = 0.0;
    _to = widget.value;
  }

  @override
  void didUpdateWidget(covariant _AnimatedValueText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      _from = _to;
      _to = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: _from, end: _to),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        return Text(widget.formatter(v), style: widget.style);
      },
      onEnd: () {
        _from = _to;
      },
    );
  }
}
