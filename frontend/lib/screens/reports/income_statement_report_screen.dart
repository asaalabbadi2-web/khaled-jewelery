import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/auth_provider.dart';
import '../../providers/settings_provider.dart';

class IncomeStatementReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const IncomeStatementReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<IncomeStatementReportScreen> createState() =>
      _IncomeStatementReportScreenState();
}

class _IncomeStatementReportScreenState
    extends State<IncomeStatementReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = false;
  String? _error;

  DateTimeRange? _selectedRange;
  String _groupBy = 'month';
  bool _includeUnposted = false;

  late NumberFormat _currencyFormat;
  final NumberFormat _weightFormat = NumberFormat('#,##0.000');

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  int _mainKarat = 21;
  String _currencyLocale = 'ar';
  bool _isCurrentLocaleArabic(BuildContext context) {
    final locale = Localizations.localeOf(context);
    return locale.languageCode.toLowerCase().startsWith('ar');
  }

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final start = DateTime(
      today.year,
      today.month,
      today.day,
    ).subtract(const Duration(days: 89));
    final end = DateTime(today.year, today.month, today.day);
    _selectedRange = DateTimeRange(start: start, end: end);

    _currencyLocale = widget.isArabic ? 'ar' : 'en';
    _currencyFormat = NumberFormat.currency(
      locale: _currencyLocale,
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimals,
    );

    _loadReport();
  }

  bool _canViewReport() {
    try {
      return context.read<AuthProvider>().hasPermission('reports.financial');
    } catch (_) {
      return false;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);
    final symbol = settings.currencySymbol;
    final decimals = settings.decimalPlaces;
    final mainKarat = settings.mainKarat;
    final localeIsArabic = _isCurrentLocaleArabic(context);
    final newCurrencyLocale = localeIsArabic ? 'ar' : 'en';

    if (symbol != _currencySymbol ||
        decimals != _currencyDecimals ||
        mainKarat != _mainKarat ||
        newCurrencyLocale != _currencyLocale) {
      _currencySymbol = symbol;
      _currencyDecimals = decimals;
      _mainKarat = mainKarat;
      _currencyLocale = newCurrencyLocale;
      _currencyFormat = NumberFormat.currency(
        locale: _currencyLocale,
        symbol: _currencySymbol,
        decimalDigits: _currencyDecimals,
      );
    }
  }

  Future<void> _loadReport() async {
    if (!_canViewReport()) {
      setState(() {
        _isLoading = false;
        _report = null;
        _error = widget.isArabic
            ? 'ليس لديك صلاحية لعرض التقارير المالية'
            : 'You do not have permission to view financial reports';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.api.getIncomeStatementReport(
        startDate: _selectedRange?.start,
        endDate: _selectedRange?.end,
        groupBy: _groupBy,
        includeUnposted: _includeUnposted,
      );
      if (!mounted) return;
      setState(() => _report = result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initialRange =
        _selectedRange ??
        DateTimeRange(start: now.subtract(const Duration(days: 89)), end: now);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: initialRange,
      locale: _isCurrentLocaleArabic(context)
          ? const Locale('ar')
          : const Locale('en'),
    );

    if (picked != null) {
      setState(() => _selectedRange = picked);
      await _loadReport();
    }
  }

  void _clearDateRange() {
    setState(() => _selectedRange = null);
    _loadReport();
  }

  double _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return 0.0;
  }

  String _formatCurrency(num value) => _currencyFormat.format(value);

  String _formatWeight(num value) =>
      '${_weightFormat.format(value)} جم (عيار $_mainKarat)';

  @override
  Widget build(BuildContext context) {
    final isArabic = _isCurrentLocaleArabic(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(isArabic ? 'قائمة الدخل' : 'Income Statement'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: isArabic ? 'تحديث' : 'Refresh',
            onPressed: _isLoading ? null : _loadReport,
          ),
        ],
      ),
      body: SafeArea(
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? _buildErrorState(isArabic)
            : _buildContent(isArabic),
      ),
    );
  }

  Widget _buildErrorState(bool isArabic) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 12),
          Text(
            isArabic ? 'فشل تحميل التقرير' : 'Failed to load report',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            _error ?? '',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadReport,
            icon: const Icon(Icons.refresh),
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(bool isArabic) {
    return RefreshIndicator(
      onRefresh: _loadReport,
      child: ListView(
        padding: const EdgeInsets.all(16),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildFiltersCard(isArabic),
          const SizedBox(height: 16),
          _buildSummaryCard(isArabic),
          const SizedBox(height: 16),
          _buildFinancialTrendCard(isArabic),
          const SizedBox(height: 16),
          _buildWeightTrendCard(isArabic),
          const SizedBox(height: 16),
          _buildSeriesTable(isArabic),
          const SizedBox(height: 16),
          _buildExpensesCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final rangeText = _selectedRange == null
        ? (isArabic ? 'آخر 90 يوم افتراضيًا' : 'Last 90 days (default)')
        : '${DateFormat('yyyy-MM-dd').format(_selectedRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_selectedRange!.end)}';

    final groupByOptions = <String, String>{
      'day': isArabic ? 'يومي' : 'Daily',
      'month': isArabic ? 'شهري' : 'Monthly',
      'quarter': isArabic ? 'ربع سنوي' : 'Quarterly',
      'year': isArabic ? 'سنوي' : 'Yearly',
    };

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'خيارات التقرير' : 'Report Options',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickDateRange,
                  icon: const Icon(Icons.date_range),
                  label: Text(rangeText),
                ),
                if (_selectedRange != null)
                  TextButton.icon(
                    onPressed: _clearDateRange,
                    icon: const Icon(Icons.clear),
                    label: Text(isArabic ? 'إلغاء التحديد' : 'Clear'),
                  ),
                Wrap(
                  spacing: 8,
                  children: groupByOptions.entries.map((entry) {
                    final selected = _groupBy == entry.key;
                    return ChoiceChip(
                      label: Text(entry.value),
                      selected: selected,
                      onSelected: (value) {
                        if (!value || selected) return;
                        setState(() => _groupBy = entry.key);
                        _loadReport();
                      },
                    );
                  }).toList(),
                ),
                FilterChip(
                  label: Text(
                    isArabic ? 'تضمين غير المرحلة' : 'Include unposted',
                  ),
                  selected: _includeUnposted,
                  onSelected: (value) {
                    setState(() => _includeUnposted = value);
                    _loadReport();
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(bool isArabic) {
    final summary = Map<String, dynamic>.from(_report?['summary'] ?? {});
    if (summary.isEmpty) {
      return _buildEmptyState(
        icon: Icons.receipt_long,
        message: isArabic
            ? 'لا توجد بيانات لهذه الفترة.'
            : 'No data for this range.',
      );
    }

    final netMarginPct = _asDouble(summary['net_margin_pct']);
    final weightNetMarginPct = _asDouble(summary['weight_net_margin_pct']);
    final manufacturingWage = _asDouble(summary['manufacturing_wage_expense']);
    final operatingExclWage = _asDouble(
      summary['operating_expenses_excl_wage'],
    );
    final operatingTotal = _asDouble(summary['operating_expenses']);

    final financialMetrics = [
      _SummaryMetric(
        label: isArabic ? 'صافي المبيعات (مالي)' : 'Net Revenue (Cash)',
        value: _formatCurrency(_asDouble(summary['net_revenue'])),
        icon: Icons.attach_money,
        color: Colors.green,
      ),
      _SummaryMetric(
        label: isArabic ? 'الربح الإجمالي (مالي)' : 'Gross Profit (Cash)',
        value: _formatCurrency(_asDouble(summary['gross_profit'])),
        icon: Icons.stacked_line_chart,
        color: Colors.blue,
      ),
      _SummaryMetric(
        label: isArabic
            ? 'مصروفات أجور المصنعية'
            : 'Manufacturing Wages Expense',
        value: _formatCurrency(manufacturingWage),
        icon: Icons.home_repair_service,
        color: Colors.brown,
      ),
      _SummaryMetric(
        label: isArabic
            ? 'المصاريف التشغيلية الأخرى'
            : 'Other Operating Expenses',
        value: _formatCurrency(operatingExclWage),
        icon: Icons.money_off,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي المصاريف (مالي)' : 'Total Expenses (Cash)',
        value: _formatCurrency(operatingTotal),
        icon: Icons.receipt_long,
        color: Colors.deepOrange,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي الربح (مالي)' : 'Net Profit (Cash)',
        value: _formatCurrency(_asDouble(summary['net_profit'])),
        icon: Icons.savings,
        color: Colors.teal,
      ),
      _SummaryMetric(
        label: isArabic ? 'هامش صافي الربح (مالي)' : 'Net Margin % (Cash)',
        value: '${netMarginPct.toStringAsFixed(2)}%',
        icon: Icons.percent,
        color: Colors.purple,
      ),
    ];

    final weightMetrics = [
      _SummaryMetric(
        label: isArabic ? 'صافي المبيعات (وزني)' : 'Net Revenue (Weight)',
        value: _formatWeight(_asDouble(summary['weight_revenue'])),
        icon: Icons.scale,
        color: Colors.green.shade700,
      ),
      _SummaryMetric(
        label: isArabic ? 'تكلفة المبيعات (وزني)' : 'Cost of Sales (Weight)',
        value: _formatWeight(_asDouble(summary['weight_cogs'])),
        icon: Icons.inventory_2,
        color: Colors.deepOrange.shade400,
      ),
      _SummaryMetric(
        label: isArabic ? 'الربح الإجمالي (وزني)' : 'Gross Profit (Weight)',
        value: _formatWeight(_asDouble(summary['weight_gross_profit'])),
        icon: Icons.stacked_line_chart,
        color: Colors.blue.shade700,
      ),
      _SummaryMetric(
        label: isArabic
            ? 'أجور المصنعية (وزني)'
            : 'Manufacturing Wages (Weight)',
        value: _formatWeight(_asDouble(summary['weight_manufacturing_wage'])),
        icon: Icons.home_repair_service,
        color: Colors.brown.shade400,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي المصاريف (وزني)' : 'Total Expenses (Weight)',
        value: _formatWeight(_asDouble(summary['weight_expenses'])),
        icon: Icons.receipt_long,
        color: Colors.deepOrange,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي الربح (وزني)' : 'Net Profit (Weight)',
        value: _formatWeight(_asDouble(summary['weight_net_profit'])),
        icon: Icons.savings,
        color: Colors.teal.shade700,
      ),
      _SummaryMetric(
        label: isArabic ? 'هامش صافي الربح (وزني)' : 'Net Margin % (Weight)',
        value: '${weightNetMarginPct.toStringAsFixed(2)}%',
        icon: Icons.percent,
        color: Colors.purple.shade300,
      ),
    ];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'المؤشرات المالية' : 'Financial Metrics',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: financialMetrics
                  .map(
                    (metric) => SizedBox(
                      width: 200,
                      child: _SummaryTile(metric: metric, isArabic: isArabic),
                    ),
                  )
                  .toList(),
            ),
            const Divider(height: 32),
            Text(
              isArabic ? 'المؤشرات الوزنية (ذهب)' : 'Weight Metrics (Gold)',
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.amber,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: weightMetrics
                  .map(
                    (metric) => SizedBox(
                      width: 200,
                      child: _SummaryTile(metric: metric, isArabic: isArabic),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 24),
            _buildWeightExpenseBreakdown(isArabic, summary),
          ],
        ),
      ),
    );
  }

  Widget _buildWeightExpenseBreakdown(
    bool isArabic,
    Map<String, dynamic> summary,
  ) {
    final postedWeight = _asDouble(summary['weight_expenses_posted']);
    final pendingWeight = _asDouble(summary['weight_expenses_pending']);
    final pendingCash = _asDouble(summary['weight_expenses_pending_cash']);
    final totalWeight = postedWeight + pendingWeight;
    final hasPending = pendingWeight.abs() > 0.0001;
    final hasPendingCash = pendingCash.abs() > 0.01;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          isArabic ? 'تفاصيل المصاريف الوزنية' : 'Weight Expense Details',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            SizedBox(
              width: 220,
              child: _InsightPill(
                icon: Icons.scale,
                label: isArabic
                    ? 'إجمالي المصاريف الوزنية'
                    : 'Total Weight Expenses',
                value: _formatWeight(totalWeight),
                color: Colors.amber.shade800,
              ),
            ),
            SizedBox(
              width: 220,
              child: _InsightPill(
                icon: Icons.verified_outlined,
                label: isArabic
                    ? 'مصاريف وزنية مرحلة'
                    : 'Posted Weight Expenses',
                value: _formatWeight(postedWeight),
                color: Colors.teal.shade600,
              ),
            ),
            SizedBox(
              width: 220,
              child: _InsightPill(
                icon: Icons.pending_actions_outlined,
                label: isArabic
                    ? 'مصاريف وزنية معلقة'
                    : 'Pending Weight Expenses',
                value: _formatWeight(pendingWeight),
                color: Colors.deepOrange.shade400,
              ),
            ),
            SizedBox(
              width: 220,
              child: _InsightPill(
                icon: Icons.currency_exchange,
                label: isArabic
                    ? 'المكافئ النقدي للمعلقة'
                    : 'Pending Cash Equivalent',
                value: _formatCurrency(pendingCash),
                color: Colors.blueGrey.shade600,
              ),
            ),
          ],
        ),
        if (hasPending || hasPendingCash)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: Colors.orange.shade700,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isArabic
                        ? 'لا تزال هناك تسويات وزنية قيد التنفيذ. نفّذ التسويات لإغلاق الفترة بأمان.'
                        : 'Pending weight settlements need execution before closing the period.',
                    style: TextStyle(
                      color: Colors.orange.shade900,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildFinancialTrendCard(bool isArabic) {
    final series = List<Map<String, dynamic>>.from(_report?['series'] ?? []);
    if (series.isEmpty) {
      return _buildEmptyState(
        icon: Icons.show_chart,
        message: isArabic ? 'لا توجد بيانات زمنية.' : 'No time series data.',
      );
    }

    final limited = series.take(12).toList();
    final spotsRevenue = <FlSpot>[];
    final spotsExpenses = <FlSpot>[];
    final spotsNet = <FlSpot>[];
    double maxValue = 0;

    for (var i = 0; i < limited.length; i++) {
      final row = limited[i];
      final netRevenue = _asDouble(row['net_revenue']);
      final expenses = _asDouble(row['expenses']);
      final netProfit = _asDouble(row['net_profit']);
      spotsRevenue.add(FlSpot(i.toDouble(), netRevenue));
      spotsExpenses.add(FlSpot(i.toDouble(), expenses));
      spotsNet.add(FlSpot(i.toDouble(), netProfit));
      maxValue = math.max(
        maxValue,
        math.max(netRevenue.abs(), math.max(expenses.abs(), netProfit.abs())),
      );
    }

    if (maxValue == 0) {
      maxValue = 1;
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'الاتجاه المالي (نقد)' : 'Financial Trend (Cash)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 280,
              child: LineChart(
                LineChartData(
                  minY: -maxValue,
                  maxY: maxValue,
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 48,
                        getTitlesWidget: (value, meta) => Text(
                          _formatCurrency(value),
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= limited.length) {
                            return const SizedBox.shrink();
                          }
                          final label =
                              limited[index]['label']?.toString() ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  gridData: FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spotsRevenue,
                      color: Colors.blue,
                      barWidth: 3,
                      isCurved: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                    LineChartBarData(
                      spots: spotsExpenses,
                      color: Colors.orange,
                      barWidth: 3,
                      isCurved: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                    LineChartBarData(
                      spots: spotsNet,
                      color: Colors.green,
                      barWidth: 3,
                      isCurved: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) {
                        return spots.map((spot) {
                          final label = limited[spot.x.toInt()]['label'];
                          final value = _formatCurrency(spot.y);
                          return LineTooltipItem(
                            '$label\n$value',
                            const TextStyle(color: Colors.white),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                _LegendChip(
                  color: Colors.blue,
                  label: isArabic ? 'صافي المبيعات' : 'Net Revenue',
                ),
                _LegendChip(
                  color: Colors.orange,
                  label: isArabic ? 'المصاريف' : 'Expenses',
                ),
                _LegendChip(
                  color: Colors.green,
                  label: isArabic ? 'صافي الربح' : 'Net Profit',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWeightTrendCard(bool isArabic) {
    final series = List<Map<String, dynamic>>.from(_report?['series'] ?? []);
    if (series.isEmpty) {
      return const SizedBox.shrink();
    }

    final limited = series.take(12).toList();
    final spotsRevenue = <FlSpot>[];
    final spotsExpenses = <FlSpot>[];
    final spotsNet = <FlSpot>[];
    double maxValue = 0;

    for (var i = 0; i < limited.length; i++) {
      final row = limited[i];
      final netRevenue = _asDouble(row['weight_revenue']);
      final expenses = _asDouble(row['weight_expenses']);
      final netProfit = _asDouble(row['weight_net_profit']);
      spotsRevenue.add(FlSpot(i.toDouble(), netRevenue));
      spotsExpenses.add(FlSpot(i.toDouble(), expenses));
      spotsNet.add(FlSpot(i.toDouble(), netProfit));
      maxValue = math.max(
        maxValue,
        math.max(netRevenue.abs(), math.max(expenses.abs(), netProfit.abs())),
      );
    }

    if (maxValue == 0) {
      maxValue = 1;
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'الاتجاه الوزني (ذهب)' : 'Weight Trend (Gold)',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 280,
              child: LineChart(
                LineChartData(
                  minY: -maxValue,
                  maxY: maxValue,
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 48,
                        getTitlesWidget: (value, meta) => Text(
                          _weightFormat.format(value),
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= limited.length) {
                            return const SizedBox.shrink();
                          }
                          final label =
                              limited[index]['label']?.toString() ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  gridData: FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spotsRevenue,
                      color: Colors.amber.shade700,
                      barWidth: 3,
                      isCurved: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                    LineChartBarData(
                      spots: spotsExpenses,
                      color: Colors.deepOrange,
                      barWidth: 3,
                      isCurved: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                    LineChartBarData(
                      spots: spotsNet,
                      color: Colors.teal.shade700,
                      barWidth: 3,
                      isCurved: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: false),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) {
                        return spots.map((spot) {
                          final label = limited[spot.x.toInt()]['label'];
                          final value = _formatWeight(spot.y);
                          return LineTooltipItem(
                            '$label\n$value',
                            const TextStyle(color: Colors.white),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              children: [
                _LegendChip(
                  color: Colors.amber.shade700,
                  label: isArabic ? 'صافي المبيعات' : 'Net Revenue',
                ),
                _LegendChip(
                  color: Colors.deepOrange,
                  label: isArabic ? 'المصاريف' : 'Expenses',
                ),
                _LegendChip(
                  color: Colors.teal.shade700,
                  label: isArabic ? 'صافي الربح' : 'Net Profit',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeriesTable(bool isArabic) {
    final series = List<Map<String, dynamic>>.from(_report?['series'] ?? []);
    if (series.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'تفاصيل الفترات' : 'Period Details',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'الفترة' : 'Period')),
                  DataColumn(
                    label: Text(
                      isArabic ? 'صافي المبيعات (نقدي)' : 'Net Revenue (Cash)',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'صافي الربح (نقدي)' : 'Net Profit (Cash)',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic
                          ? 'صافي المبيعات (وزني)'
                          : 'Net Revenue (Weight)',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'الوزن المباع الفعلي' : 'Actual Sold Weight',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'أجور مصنعية (وزني)' : 'Mfg Wages (Weight)',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'مصاريف (مرحلة)' : 'Expenses (Posted)',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'مصاريف (معلقة)' : 'Expenses (Pending)',
                    ),
                  ),
                  DataColumn(
                    label: Text(
                      isArabic ? 'صافي الربح (وزني)' : 'Net Profit (Weight)',
                    ),
                  ),
                ],
                rows: series
                    .map(
                      (row) => DataRow(
                        cells: [
                          DataCell(
                            Text(
                              row['label']?.toString() ??
                                  row['period']?.toString() ??
                                  '-',
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatCurrency(_asDouble(row['net_revenue'])),
                            ),
                          ),
                          DataCell(
                            Text(_formatCurrency(_asDouble(row['net_profit']))),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(_asDouble(row['weight_revenue'])),
                            ),
                          ),
                          DataCell(
                            Text(_formatWeight(_asDouble(row['weight_cogs']))),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(
                                _asDouble(row['weight_manufacturing_wage']),
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(
                                _asDouble(row['weight_expenses_posted']),
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(
                                _asDouble(row['weight_expenses_pending']),
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              _formatWeight(
                                _asDouble(row['weight_net_profit']),
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpensesCard(bool isArabic) {
    final expenses = List<Map<String, dynamic>>.from(
      _report?['expense_breakdown'] ?? [],
    );
    if (expenses.isEmpty) {
      return _buildEmptyState(
        icon: Icons.money_off,
        message: isArabic ? 'لا توجد مصاريف مسجلة.' : 'No expenses recorded.',
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'أعلى المصاريف' : 'Top Expenses',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            ...expenses.map((expense) {
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const CircleAvatar(child: Icon(Icons.receipt_long)),
                title: Text(expense['account_name']?.toString() ?? '-'),
                subtitle: Text(expense['account_number']?.toString() ?? ''),
                trailing: Text(_formatCurrency(_asDouble(expense['amount']))),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              message,
              style: const TextStyle(fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;

  const _InsightPill({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        color: color.withValues(alpha: 0.07),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
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
    );
  }
}

class _SummaryMetric {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
}

class _SummaryTile extends StatelessWidget {
  final _SummaryMetric metric;
  final bool isArabic;

  const _SummaryTile({required this.metric, required this.isArabic});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: [
              Icon(metric.icon, color: metric.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  metric.label,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            metric.value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}

class _LegendChip extends StatelessWidget {
  final Color color;
  final String label;

  const _LegendChip({required this.color, required this.label});

  @override
  Widget build(BuildContext context) {
    return Chip(
      avatar: CircleAvatar(backgroundColor: color, radius: 6),
      label: Text(label),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }
}
