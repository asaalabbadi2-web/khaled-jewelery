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
  Map<String, dynamic>? _gramReport;
  bool _isLoading = false;
  String? _error;

  DateTimeRange? _selectedRange;
  String _groupBy = 'month';
  bool _includeUnposted = false;

  late NumberFormat _currencyFormat;

  String _currencySymbol = '';
  int _currencyDecimals = 2;
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
    final symbol = settings.currencySymbolText;
    final decimals = settings.decimalPlaces;
    final localeIsArabic = _isCurrentLocaleArabic(context);
    final newCurrencyLocale = localeIsArabic ? 'ar' : 'en';

    if (symbol != _currencySymbol ||
        decimals != _currencyDecimals ||
        newCurrencyLocale != _currencyLocale) {
      _currencySymbol = symbol;
      _currencyDecimals = decimals;
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

      // تقرير ربح الجرام — يستخدم نفس الفترة
      try {
        final start =
            _selectedRange?.start ??
            DateTime.now().subtract(const Duration(days: 89));
        final end = _selectedRange?.end ?? DateTime.now();
        final gramResult = await widget.api.getGramProfitReport(
          startDate: start,
          endDate: end,
        );
        if (mounted) setState(() => _gramReport = gramResult);
      } catch (_) {
        if (mounted) setState(() => _gramReport = null);
      }
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
          _buildGramProfitCard(isArabic),
          const SizedBox(height: 16),
          _buildSummaryCard(isArabic),
          const SizedBox(height: 16),
          _buildFinancialTrendCard(isArabic),
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
    final manufacturingWage = _asDouble(summary['manufacturing_wage_expense']);
    final operatingTotal = _asDouble(summary['operating_expenses']);
    final costOfSales = _asDouble(summary['cost_of_sales']);
    final costBasisNote = (summary['cost_basis_note'] ?? '').toString();

    final financialMetrics = [
      _SummaryMetric(
        label: isArabic ? 'صافي المبيعات (مالي)' : 'Net Revenue (Cash)',
        value: _formatCurrency(_asDouble(summary['net_revenue'])),
        icon: Icons.attach_money,
        color: Colors.green,
      ),
      // The chart's 51 «تكلفة المبيعات» -- the wages among it (11 Oct 2026).
      _SummaryMetric(
        label: isArabic ? 'تكلفة المبيعات' : 'Cost of Sales',
        value: _formatCurrency(costOfSales),
        icon: Icons.inventory_2_outlined,
        color: Theme.of(context).colorScheme.secondary,
      ),
      _SummaryMetric(
        label: isArabic ? 'الربح الإجمالي (مالي)' : 'Gross Profit (Cash)',
        value: _formatCurrency(_asDouble(summary['gross_profit'])),
        icon: Icons.stacked_line_chart,
        color: Colors.blue,
      ),
      _SummaryMetric(
        label: isArabic
            ? 'منها أجور المصنعية'
            : 'of which manufacturing wages',
        value: _formatCurrency(manufacturingWage),
        icon: Icons.home_repair_service,
        color: Colors.brown,
      ),
      _SummaryMetric(
        label: isArabic ? 'المصاريف التشغيلية' : 'Operating Expenses',
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
            // Until the perpetual cost by weight is in (the owner, 11 Oct
            // 2026), the cost of sales is the purchases' -- said, not hidden.
            if (costBasisNote.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                costBasisNote,
                key: const Key('income-cost-basis-note'),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ],
        ),
      ),
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

  Widget _buildGramProfitCard(bool isArabic) {
    final g = _gramReport;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    const goldColor = Color(0xFFFFD700);
    final darkGold = const Color(0xFF7A5C00);

    if (g == null) {
      return AnimatedSwitcher(
        duration: const Duration(milliseconds: 300),
        child: _isLoading
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(child: CircularProgressIndicator()),
              )
            : Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    isArabic
                        ? 'لا توجد بيانات لهذه الفترة'
                        : 'No data for this period',
                    style: TextStyle(color: Colors.grey.shade500),
                  ),
                ),
              ),
      );
    }

    double val(String key) {
      final v = g[key];
      if (v is num) return v.toDouble();
      return 0.0;
    }

    // unavailable_reason هو مصدر الحقيقة — يُفحص قبل أي استخدام للحقول المشتقة من avg_buy
    final unavailableReason = g['unavailable_reason'] as String?;
    if (unavailableReason != null) {
      final reasonLabel = {
        'no_cash_purchases': isArabic
            ? 'لا مشتريات نقدية في هذه الفترة'
            : 'No cash purchases in this period',
        'avg_buy_out_of_range': isArabic
            ? 'متوسط الشراء خارج النطاق المتوقع'
            : 'Avg buy price out of expected range',
      }[unavailableReason] ??
          (isArabic
              ? 'بيانات غير كافية لحساب ربح الجرام'
              : 'Insufficient data to compute gram profit');
      final mainKarat = g['main_karat']?.toString() ?? '21';
      final wSold = val('weight_sold').toStringAsFixed(3);
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDark
                ? [const Color(0xFF1D1800), const Color(0xFF0F0E00)]
                : [const Color(0xFFFFFDE7), const Color(0xFFFFF8E1)],
          ),
          border: Border.all(color: goldColor.withOpacity(0.3), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(Icons.warning_amber_rounded,
                        color: Colors.orange, size: 22),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isArabic ? 'ربح الجرام الذهبي' : 'Gold Gram Profit',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.orange.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            isArabic ? 'غير محسوب' : 'Unavailable',
                            style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: Colors.orange,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                reasonLabel,
                style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 16),
              _GramStatRow(
                items: [
                  _GramStat(
                    label: isArabic ? 'إجمالي المبيعات' : 'Total Sales',
                    value: _formatCurrency(val('total_sales_cash')),
                    icon: Icons.receipt,
                    color: Colors.green.shade700,
                    isDark: isDark,
                  ),
                  _GramStat(
                    label: isArabic
                        ? 'وزن مباع ($mainKarat)'
                        : 'Sold (${mainKarat}k)',
                    value: '$wSold ${isArabic ? "جم" : "g"}',
                    icon: Icons.trending_up,
                    color: Colors.blue,
                    isDark: isDark,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _GramStatRow(
                items: [
                  _GramStat(
                    label: isArabic ? 'متوسط بيع/جم' : 'Avg sell/g',
                    value: _formatCurrency(val('avg_sell_per_gram')),
                    icon: Icons.sell,
                    color: Colors.green,
                    isDark: isDark,
                  ),
                  _GramStat(
                    label: isArabic ? 'متوسط شراء/جم' : 'Avg buy/g',
                    value: isArabic ? '—' : '—',
                    icon: Icons.shopping_bag,
                    color: Colors.orange,
                    isDark: isDark,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final weightSold = val('weight_sold');
    final weightBought = val('weight_purchased');
    final avgSell = val('avg_sell_per_gram');
    final avgBuy = val('avg_buy_per_gram');
    final marginPerGram = val('margin_per_gram');
    final tradingProfitWeight = val('trading_profit_weight');
    final extraRevWDirect = val('extra_revenue_weight');
    final extraRevCash = val('extra_revenue_cash');
    final extraRevCashW = val('extra_revenue_cash_as_weight');
    final expWeightDirect = val('expense_weight_direct');
    final expCashTotal = val('expense_cash_total');
    final expCashWeight = val('expense_cash_as_weight');
    final netProfit = val('net_profit');
    final netProfitWeight = val('net_profit_weight');
    // ⑤ and the price every weight layer is shown at in riyals: the shop's own
    // recent purchase price, as the engine values the waiting riyals (ADR-048).
    final priceEffectWeight = val('price_effect_weight');
    final valuationPrice = val('valuation_price_per_gram') > 0 ? val('valuation_price_per_gram') : avgBuy;
    final netMarginPct = val('net_margin_pct');
    final totalSales = val('total_sales_cash');
    final mainKarat = g['main_karat']?.toString() ?? '21';
    final isProfit = netProfitWeight >= 0;

    final profitColor = isProfit ? Colors.green.shade600 : Colors.red.shade600;
    final profitBg = isProfit
        ? Colors.green.withOpacity(0.08)
        : Colors.red.withOpacity(0.08);

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: isDark
              ? [const Color(0xFF1D1800), const Color(0xFF0F0E00)]
              : [const Color(0xFFFFFDE7), const Color(0xFFFFF8E1)],
        ),
        border: Border.all(color: goldColor.withOpacity(0.3), width: 1.5),
        boxShadow: [
          BoxShadow(
            color: goldColor.withOpacity(0.10),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Title ──────────────────────────────────────────────
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        goldColor.withOpacity(0.25),
                        goldColor.withOpacity(0.10),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.auto_graph,
                    color: goldColor,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArabic ? 'ربح الجرام الذهبي' : 'Gold Gram Profit',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: isDark ? goldColor : darkGold,
                        ),
                      ),
                      Text(
                        isArabic
                            ? 'ما اشترته ريالات مبيعاتك من ذهب − ما بعته، وما ينتظر بسعر شرائك'
                            : 'The gold your sales riyals bought − what you sold; what waits, at your buy price',
                        style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── Net Profit Hero ────────────────────────────────────
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 20),
              decoration: BoxDecoration(
                color: profitBg,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: profitColor.withOpacity(0.25)),
              ),
              child: Column(
                children: [
                  Text(
                    isArabic ? 'صافي الربح الوزني' : 'Net Weight Profit',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.scale, size: 22, color: profitColor),
                      const SizedBox(width: 8),
                      Text(
                        '${netProfitWeight.toStringAsFixed(3)} ${isArabic ? "جم" : "g"}',
                        style: TextStyle(
                          fontSize: 30,
                          fontWeight: FontWeight.bold,
                          color: profitColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isArabic ? '(عيار $mainKarat)' : '(K$mainKarat)',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: profitColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '≈ ${_formatCurrency(netProfit)}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: profitColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: profitColor.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${netMarginPct.toStringAsFixed(1)}% ${isArabic ? "هامش" : "margin"}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: profitColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── Stat Cards ─────────────────────────────────────────
            _GramStatRow(
              items: [
                _GramStat(
                  label: isArabic
                      ? 'وزن مباع ($mainKarat)'
                      : 'Sold ($mainKarat k)',
                  value: '${weightSold.toStringAsFixed(3)} جم',
                  icon: Icons.trending_up,
                  color: Colors.blue,
                  isDark: isDark,
                ),
                _GramStat(
                  label: isArabic
                      ? 'وزن مشترى ($mainKarat)'
                      : 'Bought ($mainKarat k)',
                  value: '${weightBought.toStringAsFixed(3)} جم',
                  icon: Icons.trending_down,
                  color: Colors.indigo,
                  isDark: isDark,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _GramStatRow(
              items: [
                _GramStat(
                  label: isArabic ? 'متوسط بيع/جم' : 'Avg sell/g',
                  value: _formatCurrency(avgSell),
                  icon: Icons.sell,
                  color: Colors.green,
                  isDark: isDark,
                ),
                _GramStat(
                  label: isArabic ? 'متوسط شراء/جم' : 'Avg buy/g',
                  value: _formatCurrency(avgBuy),
                  icon: Icons.shopping_bag,
                  color: Colors.orange,
                  isDark: isDark,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _GramStatRow(
              items: [
                _GramStat(
                  label: isArabic ? 'فارق الجرام' : 'Margin/g',
                  value: _formatCurrency(marginPerGram),
                  icon: Icons.swap_horiz,
                  color: marginPerGram >= 0 ? Colors.teal : Colors.red,
                  isDark: isDark,
                ),
                _GramStat(
                  label: isArabic ? 'إجمالي المبيعات' : 'Total Sales',
                  value: _formatCurrency(totalSales),
                  icon: Icons.receipt,
                  color: Colors.green.shade700,
                  isDark: isDark,
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── Profit Waterfall ───────────────────────────────────
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.03)
                    : Colors.white.withOpacity(0.7),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: goldColor.withOpacity(0.12)),
              ),
              child: Column(
                children: [
                  _ProfitStep(
                    label: isArabic
                        ? '① المتاجرة: ريالات المُباع التي عادت ذهبًا'
                        : '① Trading: sales riyals turned back into gold',
                    value: tradingProfitWeight * valuationPrice,
                    currencySymbol: _currencySymbol,
                    weightEquiv: tradingProfitWeight,
                    isFirst: true,
                    isSubtract: false,
                    isDark: isDark,
                  ),
                  _ProfitStep(
                    label: isArabic
                        ? '② إيرادات وزنية مباشرة'
                        : '② Weight Revenue (direct)',
                    value: extraRevWDirect * valuationPrice,
                    currencySymbol: _currencySymbol,
                    weightEquiv: extraRevWDirect,
                    isSubtract: false,
                    isDark: isDark,
                  ),
                  if (extraRevCash.abs() > 0.01)
                    _ProfitStep(
                      label: isArabic
                          ? '② إيرادات نقدية (ما اشترته ريالاتها)'
                          : '② Cash Revenue (what its riyals bought)',
                      value: extraRevCash,
                      currencySymbol: _currencySymbol,
                      weightEquiv: extraRevCashW,
                      isSubtract: false,
                      isDark: isDark,
                    ),
                  _ProfitStep(
                    label: isArabic
                        ? '③ مصاريف وزنية مباشرة'
                        : '③ Weight Expenses (direct)',
                    value: expWeightDirect * valuationPrice,
                    currencySymbol: _currencySymbol,
                    weightEquiv: expWeightDirect,
                    isSubtract: true,
                    isDark: isDark,
                  ),
                  _ProfitStep(
                    label: isArabic
                        ? '④ مصاريف نقدية (الغرامات المُباعة التي أنفقت ريالاتها)'
                        : '④ Cash Expenses (the grams sold whose riyals they spent)',
                    value: expCashTotal,
                    currencySymbol: _currencySymbol,
                    weightEquiv: expCashWeight,
                    isSubtract: true,
                    isDark: isDark,
                  ),
                  _ProfitStep(
                    label: isArabic
                        ? '⑤ أثر السعر على المفتوح'
                        : '⑤ The price on what still waits',
                    value: priceEffectWeight * valuationPrice,
                    currencySymbol: _currencySymbol,
                    weightEquiv: priceEffectWeight,
                    isSubtract: priceEffectWeight < 0,
                    isDark: isDark,
                  ),
                  const Divider(height: 8),
                  _ProfitStep(
                    label: isArabic ? 'صافي الربح الوزني' : 'Net Weight Profit',
                    value: netProfit,
                    currencySymbol: _currencySymbol,
                    weightEquiv: netProfitWeight,
                    isSubtotalRow: true,
                    isSubtract: false,
                    isDark: isDark,
                  ),
                ],
              ),
            ),

            // ── Methodology Note ──────────────────────────────────
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: isDark
                    ? Colors.white.withOpacity(0.04)
                    : Colors.grey.shade50,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: Colors.grey.shade500,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isArabic
                          ? 'الربح الوزني = ① المتاجرة + ② الإيرادات − ③ المصاريف الوزنية − ④ المصاريف النقدية ± ⑤ أثر السعر على ما لم يُسكَّر بعد. ما عاد ذهبًا يُحسب بما اشتراه فعلًا، وما ينتظر بسعر شرائك في آخر 7 أيام شراء. الحسابات المشاركة من شجرة الحسابات (علم "يدخل في ربح الجرام").'
                          : 'Weight profit = ① trading + ② revenues − ③ weight expenses − ④ cash expenses ± ⑤ the price on what still waits. What became gold counts at what it bought; what waits, at your purchase price of the last 7 purchase days.',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ),
                ],
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

// ─── Gram Profit Helpers ─────────────────────────────────────────────────────

class _GramStat {
  final String label;
  final String value;
  final IconData icon;
  final Color color;
  final bool isDark;

  const _GramStat({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
    required this.isDark,
  });
}

class _ProfitStep extends StatelessWidget {
  final String label;
  final double value;
  final String currencySymbol;
  final double? weightEquiv;
  final bool isSubtract;
  final bool isFirst;
  final bool isSubtotalRow;
  final bool isDark;

  const _ProfitStep({
    required this.label,
    required this.value,
    required this.currencySymbol,
    this.weightEquiv,
    this.isSubtract = false,
    this.isFirst = false,
    this.isSubtotalRow = false,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSubtotalRow
        ? Colors.blueGrey
        : isSubtract
        ? Colors.red.shade700
        : Colors.teal.shade700;

    final bgColor = isSubtotalRow
        ? (isDark ? Colors.blueGrey.withOpacity(0.15) : Colors.blueGrey.shade50)
        : (isDark ? Colors.white.withOpacity(0.03) : Colors.grey.shade50);

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(10),
        border: isSubtotalRow
            ? Border.all(color: Colors.blueGrey.withOpacity(0.3))
            : null,
      ),
      child: Row(
        children: [
          Text(
            isFirst ? '' : (isSubtract ? '−' : '+'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: isSubtotalRow ? 13 : 12,
                fontWeight: isSubtotalRow ? FontWeight.w600 : FontWeight.normal,
                color: isDark ? Colors.white70 : Colors.grey.shade700,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Row(
                children: [
                  Text(
                    NumberFormat('#,##0.00').format(value),
                    style: TextStyle(
                      fontSize: isSubtotalRow ? 14 : 13,
                      fontWeight: isSubtotalRow
                          ? FontWeight.bold
                          : FontWeight.w600,
                      color: color,
                    ),
                  ),
                  Text(
                    ' $currencySymbol',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
              if (weightEquiv != null)
                Text(
                  '≈ ${weightEquiv!.toStringAsFixed(3)} جم',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: color.withOpacity(0.8),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _GramStatRow extends StatelessWidget {
  final List<_GramStat> items;

  const _GramStatRow({required this.items});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: items.map((s) {
        return Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
            decoration: BoxDecoration(
              color: s.color.withOpacity(s.isDark ? 0.12 : 0.07),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: s.color.withOpacity(0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(s.icon, size: 14, color: s.color),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        s.label,
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey.shade600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  s.value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: s.color,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }
}
