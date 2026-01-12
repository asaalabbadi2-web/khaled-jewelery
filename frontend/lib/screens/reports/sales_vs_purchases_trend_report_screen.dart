import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

class SalesVsPurchasesTrendReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SalesVsPurchasesTrendReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<SalesVsPurchasesTrendReportScreen> createState() =>
      _SalesVsPurchasesTrendReportScreenState();
}

class _SalesVsPurchasesTrendReportScreenState
    extends State<SalesVsPurchasesTrendReportScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic>? _summary;
  List<Map<String, dynamic>> _timeline = [];

  DateTimeRange? _selectedRange;
  String _groupInterval = 'day';
  bool _includeUnposted = false;
  String? _goldType;

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  late NumberFormat _currencyFormat;
  final NumberFormat _weightFormat = NumberFormat('#,##0.000');

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final todayDate = DateTime(today.year, today.month, today.day);
    _selectedRange = DateTimeRange(
      start: todayDate.subtract(const Duration(days: 29)),
      end: todayDate,
    );
    _currencyFormat = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: _currencySymbol,
      decimalDigits: _currencyDecimals,
    );
    _loadReport();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context, listen: true);
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

  Future<void> _loadReport() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.api.getSalesVsPurchasesTrend(
        startDate: _selectedRange?.start,
        endDate: _selectedRange?.end,
        groupInterval: _groupInterval,
        includeUnposted: _includeUnposted,
        goldType: _goldType,
      );

      if (!mounted) return;
      setState(() {
        _summary = Map<String, dynamic>.from(result['summary'] ?? {});
        final timeline = List<Map<String, dynamic>>.from(
          result['timeline'] ?? [],
        );
        _timeline = timeline;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    final initialRange =
        _selectedRange ??
        DateTimeRange(start: now.subtract(const Duration(days: 29)), end: now);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 5),
      lastDate: DateTime(now.year + 1),
      initialDateRange: initialRange,
      locale: widget.isArabic ? const Locale('ar') : const Locale('en'),
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

  String _formatCurrency(num value) => _currencyFormat.format(value);

  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  double _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isArabic
                ? 'تقرير اتجاه المبيعات والمشتريات'
                : 'Sales vs Purchases Trend',
          ),
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
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade400),
          const SizedBox(height: 12),
          Text(
            isArabic ? 'تعذّر تحميل التقرير' : 'Failed to load report',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _error ?? '',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.grey),
            ),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: _loadReport,
            icon: const Icon(Icons.refresh),
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try Again'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final isArabic = widget.isArabic;
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
          _buildTrendChartCard(isArabic),
          const SizedBox(height: 16),
          _buildTimelineTable(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final rangeText = _selectedRange == null
        ? (isArabic ? 'كل الفترات' : 'All time')
        : '${DateFormat('yyyy-MM-dd').format(_selectedRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_selectedRange!.end)}';

    final intervalLabels = {
      'day': isArabic ? 'يومي' : 'Daily',
      'week': isArabic ? 'أسبوعي' : 'Weekly',
      'month': isArabic ? 'شهري' : 'Monthly',
    };

    final goldTypeLabels = <String, String>{
      'new': isArabic ? 'ذهب جديد' : 'New Gold',
      'scrap': isArabic ? 'ذهب كسر' : 'Scrap Gold',
      'unspecified': isArabic ? 'غير محدد' : 'Unspecified',
    };

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'خيارات التقرير' : 'Report Filters',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
                  children: intervalLabels.entries.map((entry) {
                    final selected = _groupInterval == entry.key;
                    return ChoiceChip(
                      label: Text(entry.value),
                      selected: selected,
                      onSelected: (value) {
                        if (!value || _groupInterval == entry.key) return;
                        setState(() => _groupInterval = entry.key);
                        _loadReport();
                      },
                    );
                  }).toList(),
                ),
                FilterChip(
                  label: Text(
                    isArabic ? 'تضمين غير المرحلة' : 'Include Unposted',
                  ),
                  selected: _includeUnposted,
                  onSelected: (value) {
                    setState(() => _includeUnposted = value);
                    _loadReport();
                  },
                ),
                DropdownButton<String?>(
                  value: _goldType,
                  hint: Text(isArabic ? 'نوع الذهب' : 'Gold Type'),
                  items: [
                    DropdownMenuItem(
                      value: null,
                      child: Text(isArabic ? 'كل الأنواع' : 'All types'),
                    ),
                    ...goldTypeLabels.entries.map(
                      (entry) => DropdownMenuItem(
                        value: entry.key,
                        child: Text(entry.value),
                      ),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() => _goldType = value);
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
    final summary = _summary ?? {};
    if (summary.isEmpty) {
      return _buildEmptyState(
        icon: Icons.insert_chart_outlined,
        message: isArabic ? 'لا توجد بيانات لعرضها.' : 'No data to display.',
      );
    }

    final metrics = [
      _SummaryMetric(
        label: isArabic ? 'إجمالي المبيعات' : 'Total Sales',
        value: _formatCurrency(_asDouble(summary['sales_total'] ?? 0)),
        icon: Icons.trending_up,
        color: Colors.green,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي المشتريات' : 'Total Purchases',
        value: _formatCurrency(_asDouble(summary['purchases_total'] ?? 0)),
        icon: Icons.shopping_cart,
        color: Colors.blue,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي القيمة' : 'Net Total',
        value: _formatCurrency(_asDouble(summary['net_total'] ?? 0)),
        icon: Icons.currency_exchange,
        color: summary['net_total'] >= 0 ? Colors.teal : Colors.redAccent,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي الوزن (جم)' : 'Net Weight (g)',
        value: _formatWeight(_asDouble(summary['net_weight'] ?? 0)),
        icon: Icons.scale,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'هامش المبيعات (ر.س)' : 'Sales Margin (Cash)',
        value: _formatCurrency(_asDouble(summary['sales_margin_cash'] ?? 0)),
        icon: Icons.stacked_line_chart,
        color: Colors.purple,
      ),
      _SummaryMetric(
        label: isArabic ? 'هامش المشتريات (ر.س)' : 'Purchases Margin (Cash)',
        value: _formatCurrency(
          _asDouble(summary['purchases_margin_cash'] ?? 0),
        ),
        icon: Icons.insights,
        color: Colors.indigo,
      ),
    ];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 16,
          runSpacing: 16,
          children: metrics
              .map(
                (metric) => SizedBox(
                  width: 220,
                  child: _SummaryTile(metric: metric, isArabic: isArabic),
                ),
              )
              .toList(),
        ),
      ),
    );
  }

  Widget _buildTrendChartCard(bool isArabic) {
    if (_timeline.isEmpty) {
      return _buildEmptyState(
        icon: Icons.query_stats,
        message: isArabic
            ? 'اختر نطاقًا زمنيًا أو فلترًا مختلفًا لرؤية الاتجاه.'
            : 'Select another date range or filters to view the trend.',
      );
    }

    final salesSpots = _buildSpots('sales_total');
    final purchaseSpots = _buildSpots('purchases_total');

    final maxY = [
      ...salesSpots.map((spot) => spot.y),
      ...purchaseSpots.map((spot) => spot.y),
    ].fold<double>(0.0, (prev, value) => value > prev ? value : prev);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'الاتجاه الزمني للقيمة' : 'Value Trend Over Time',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 320,
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: (_timeline.length - 1).toDouble(),
                  minY: 0,
                  maxY: maxY == 0 ? 1 : maxY * 1.15,
                  gridData: const FlGridData(
                    show: true,
                    drawVerticalLine: false,
                  ),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: _timeline.length > 8 ? 2 : 1,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= _timeline.length) {
                            return const SizedBox.shrink();
                          }
                          final label = _timeline[index]['label'] ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              label,
                              style: const TextStyle(fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: maxY == 0 ? 1 : maxY / 4,
                        getTitlesWidget: (value, _) => Text(
                          _compactCurrency(value),
                          style: const TextStyle(fontSize: 10),
                        ),
                      ),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (touchSpots) => touchSpots.map((spot) {
                        final label = _timeline[spot.x.toInt()]['label'];
                        return LineTooltipItem(
                          '$label\n${spot.barIndex == 0 ? (isArabic ? 'مبيعات: ' : 'Sales: ') : (isArabic ? 'مشتريات: ' : 'Purchases: ')}${_formatCurrency(spot.y)}',
                          const TextStyle(color: Colors.white),
                        );
                      }).toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: salesSpots,
                      isCurved: true,
                      barWidth: 3,
                      color: Colors.green,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.green.withValues(alpha: 0.12),
                      ),
                    ),
                    LineChartBarData(
                      spots: purchaseSpots,
                      isCurved: true,
                      barWidth: 3,
                      color: Colors.blue,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        color: Colors.blue.withValues(alpha: 0.12),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 16,
              children: [
                _LegendChip(
                  color: Colors.green,
                  label: isArabic ? 'المبيعات' : 'Sales',
                ),
                _LegendChip(
                  color: Colors.blue,
                  label: isArabic ? 'المشتريات' : 'Purchases',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimelineTable(bool isArabic) {
    if (_timeline.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'تفاصيل الفترة' : 'Period Details',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'الفترة' : 'Period')),
                  DataColumn(label: Text(isArabic ? 'المبيعات' : 'Sales')),
                  DataColumn(label: Text(isArabic ? 'المشتريات' : 'Purchases')),
                  DataColumn(label: Text(isArabic ? 'الصافي' : 'Net')),
                  DataColumn(
                    label: Text(isArabic ? 'الوزن الصافي' : 'Net Weight'),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'عدد المستندات' : 'Documents'),
                  ),
                ],
                rows: _timeline.map((row) {
                  final sales = _formatCurrency(
                    _asDouble(row['sales_total'] ?? 0),
                  );
                  final purchases = _formatCurrency(
                    _asDouble(row['purchases_total'] ?? 0),
                  );
                  final net = _formatCurrency(_asDouble(row['net_total'] ?? 0));
                  final netWeight = _formatWeight(
                    _asDouble(row['net_weight'] ?? 0),
                  );
                  final docCount =
                      (row['sales_count'] ?? 0) + (row['purchases_count'] ?? 0);
                  return DataRow(
                    cells: [
                      DataCell(Text(row['label'] ?? '')),
                      DataCell(Text(sales)),
                      DataCell(Text(purchases)),
                      DataCell(Text(net)),
                      DataCell(Text(netWeight)),
                      DataCell(Text('$docCount')),
                    ],
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Container(
      height: 140,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<FlSpot> _buildSpots(String field) {
    final spots = <FlSpot>[];
    for (var i = 0; i < _timeline.length; i++) {
      final value = _timeline[i][field];
      if (value == null) continue;
      final doubleValue = _asDouble(value);
      spots.add(FlSpot(i.toDouble(), doubleValue));
    }
    if (spots.isEmpty) {
      return [FlSpot(0, 0)];
    }
    return spots;
  }

  String _compactCurrency(num value) {
    final compact = NumberFormat.compactCurrency(
      symbol: _currencySymbol,
      decimalDigits: 0,
    );
    return compact.format(value);
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
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            backgroundColor: metric.color.withValues(alpha: 0.12),
            child: Icon(metric.icon, color: metric.color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: isArabic
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  metric.label,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 4),
                Text(
                  metric.value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(radius: 4, backgroundColor: color),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
