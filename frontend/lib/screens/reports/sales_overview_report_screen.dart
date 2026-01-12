import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

enum _ChartType { curvedLine, straightLine, bar }

class SalesOverviewReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SalesOverviewReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<SalesOverviewReportScreen> createState() =>
      _SalesOverviewReportScreenState();
}

class _SalesOverviewReportScreenState extends State<SalesOverviewReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = false;
  String? _error;

  DateTimeRange? _selectedRange;
  String _groupBy = 'day';
  bool _includeUnposted = false;
  _ChartType _chartType = _ChartType.curvedLine;

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  int _mainKarat = 21;

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;

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
    _weightFormat = NumberFormat('#,##0.000');
    _loadReport();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final settings = Provider.of<SettingsProvider>(context);

    final symbol = settings.currencySymbol;
    final decimals = settings.decimalPlaces;
    final mainKarat = settings.mainKarat;

    if (symbol != _currencySymbol ||
        decimals != _currencyDecimals ||
        mainKarat != _mainKarat) {
      setState(() {
        _currencySymbol = symbol;
        _currencyDecimals = decimals;
        _mainKarat = mainKarat;
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
      final result = await widget.api.getSalesOverviewReport(
        startDate: _selectedRange?.start,
        endDate: _selectedRange?.end,
        groupBy: _groupBy,
        includeUnposted: _includeUnposted,
      );

      if (!mounted) return;
      setState(() {
        _report = result;
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
      setState(() {
        _selectedRange = picked;
      });
      await _loadReport();
    }
  }

  void _clearDateRange() {
    setState(() {
      _selectedRange = null;
    });
    _loadReport();
  }

  double _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return 0.0;
  }

  String _formatCurrency(num value) => _currencyFormat.format(value);

  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            isArabic ? 'تقرير ملخص المبيعات' : 'Sales Overview Report',
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
          _buildGoldTypeCard(isArabic),
          const SizedBox(height: 16),
          _buildSeriesCard(isArabic),
          const SizedBox(height: 16),
          _buildTopCustomersCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final rangeText = _selectedRange == null
        ? (isArabic ? 'كل الفترات' : 'All time')
        : '${DateFormat('yyyy-MM-dd').format(_selectedRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_selectedRange!.end)}';

    final chipLabels = <String, String>{
      'day': isArabic ? 'يومي' : 'Daily',
      'month': isArabic ? 'شهري' : 'Monthly',
      'year': isArabic ? 'سنوي' : 'Yearly',
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
              isArabic ? 'خيارات التقرير' : 'Report Options',
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
                  children: chipLabels.entries.map((entry) {
                    final selected = _groupBy == entry.key;
                    return ChoiceChip(
                      label: Text(entry.value),
                      selected: selected,
                      onSelected: (value) {
                        if (!value || _groupBy == entry.key) return;
                        setState(() => _groupBy = entry.key);
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
        icon: Icons.bar_chart,
        message: isArabic ? 'لا توجد بيانات للعرض.' : 'No data available.',
      );
    }

    final items = [
      _SummaryMetric(
        label: isArabic ? 'صافي المبيعات' : 'Net Sales',
        value: _formatCurrency(_asDouble(summary['net_sales_value'])),
        icon: Icons.trending_up,
        color: Colors.green,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي الفواتير' : 'Total Documents',
        value: '${summary['total_documents'] ?? 0}',
        icon: Icons.receipt_long,
        color: Colors.blue,
      ),
      _SummaryMetric(
        label: isArabic ? 'متوسط الفاتورة' : 'Average Invoice',
        value: _formatCurrency(_asDouble(summary['average_invoice_value'])),
        icon: Icons.payments,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي الوزن' : 'Net Weight',
        value:
            '${_formatWeight(_asDouble(summary['net_gold_weight']))} (عيار $_mainKarat)',
        icon: Icons.scale,
        color: Colors.purple,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي المرتجعات' : 'Returns',
        value: _formatCurrency(_asDouble(summary['returns_value'])),
        icon: Icons.undo,
        color: Colors.redAccent,
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
          children: items
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

  Widget _buildGoldTypeCard(bool isArabic) {
    final summary = Map<String, dynamic>.from(_report?['summary'] ?? {});
    final byGoldType = Map<String, dynamic>.from(summary['by_gold_type'] ?? {});
    if (byGoldType.isEmpty) {
      return const SizedBox.shrink();
    }

    String goldTypeLabel(String key) {
      switch (key) {
        case 'new':
          return isArabic ? 'ذهب جديد' : 'New Gold';
        case 'scrap':
          return isArabic ? 'ذهب مستعمل' : 'Scrap Gold';
        case 'unspecified':
          return isArabic ? 'غير محدد' : 'Unspecified';
        default:
          return key;
      }
    }

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
              isArabic ? 'حسب نوع الذهب' : 'By Gold Type',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: byGoldType.entries.map((entry) {
                final data = Map<String, dynamic>.from(entry.value as Map);
                return Container(
                  width: 200,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.teal.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: isArabic
                        ? CrossAxisAlignment.end
                        : CrossAxisAlignment.start,
                    children: [
                      Text(
                        goldTypeLabel(entry.key),
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${isArabic ? 'عدد المستندات:' : 'Documents:'} ${data['count']}',
                      ),
                      Text(
                        '${isArabic ? 'صافي المبيعات:' : 'Net Sales:'} ${_formatCurrency(_asDouble(data['net_value']))}',
                      ),
                      Text(
                        '${isArabic ? 'صافي الوزن:' : 'Net Weight:'} ${_formatWeight(_asDouble(data['net_weight']))}',
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSeriesCard(bool isArabic) {
    final series = (_report?['series'] as List<dynamic>? ?? [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();

    final chartTypeLabels = <_ChartType, String>{
      _ChartType.curvedLine: isArabic ? 'خط منحني' : 'Curved Line',
      _ChartType.straightLine: isArabic ? 'خط مستقيم' : 'Straight Line',
      _ChartType.bar: isArabic ? 'أعمدة' : 'Bar',
    };
    final chartTypeIcons = <_ChartType, IconData>{
      _ChartType.curvedLine: Icons.show_chart,
      _ChartType.straightLine: Icons.linear_scale,
      _ChartType.bar: Icons.bar_chart,
    };

    if (series.isEmpty) {
      return _buildEmptyState(
        icon: Icons.stacked_line_chart,
        message: isArabic ? 'لا توجد بيانات زمنية.' : 'No time-series data.',
      );
    }

    final hasNonZeroValues = series.any(
      (row) => _asDouble(row['net_value']).abs() > 0,
    );

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
              isArabic ? 'الأداء الزمني' : 'Time Series',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: chartTypeLabels.entries.map((entry) {
                final selected = _chartType == entry.key;
                final icon = chartTypeIcons[entry.key] ?? Icons.show_chart;
                return Tooltip(
                  message: entry.value,
                  child: ChoiceChip(
                    label: Icon(icon, size: 16),
                    selected: selected,
                    visualDensity: VisualDensity.compact,
                    labelPadding: const EdgeInsets.all(6),
                    selectedColor: Theme.of(
                      context,
                    ).colorScheme.primary.withValues(alpha: 0.14),
                    onSelected: (value) {
                      if (!value || _chartType == entry.key) return;
                      setState(() => _chartType = entry.key);
                    },
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 12),
            if (hasNonZeroValues)
              SizedBox(
                height: 260,
                child: _SalesTrendChart(
                  data: series,
                  formatCurrency: _formatCurrency,
                  isArabic: isArabic,
                  chartType: _chartType,
                ),
              )
            else
              _buildEmptyState(
                icon: Icons.show_chart,
                message: isArabic
                    ? 'جميع القيم صفرية خلال الفترة.'
                    : 'All values are zero in the selected period.',
              ),
            const SizedBox(height: 16),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'الفترة' : 'Period')),
                  DataColumn(
                    label: Text(isArabic ? 'صافي المبيعات' : 'Net Sales'),
                  ),
                  DataColumn(label: Text(isArabic ? 'المبيعات' : 'Sales')),
                  DataColumn(label: Text(isArabic ? 'المرتجعات' : 'Returns')),
                  DataColumn(
                    label: Text(isArabic ? 'صافي الوزن' : 'Net Weight'),
                  ),
                ],
                rows: series.map((row) {
                  return DataRow(
                    cells: [
                      DataCell(Text(row['period'].toString())),
                      DataCell(
                        Text(_formatCurrency(_asDouble(row['net_value']))),
                      ),
                      DataCell(
                        Text(_formatCurrency(_asDouble(row['sales_value']))),
                      ),
                      DataCell(
                        Text(_formatCurrency(_asDouble(row['returns_value']))),
                      ),
                      DataCell(
                        Text(_formatWeight(_asDouble(row['net_weight']))),
                      ),
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

  Widget _buildTopCustomersCard(bool isArabic) {
    final topCustomers = (_report?['top_customers'] as List<dynamic>? ?? [])
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();

    if (topCustomers.isEmpty) {
      return const SizedBox.shrink();
    }

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
              isArabic ? 'أفضل العملاء' : 'Top Customers',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            ...topCustomers.map((customer) {
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: Colors.blueGrey.shade100,
                  child: const Icon(Icons.person, color: Colors.blueGrey),
                ),
                title: Text(customer['name']?.toString() ?? '-'),
                subtitle: Text(
                  '${isArabic ? 'المستندات:' : 'Documents:'} ${customer['documents'] ?? 0}\n'
                  '${isArabic ? 'صافي المبيعات:' : 'Net Sales:'} ${_formatCurrency(_asDouble(customer['net_value']))}\n'
                  '${isArabic ? 'صافي الوزن:' : 'Net Weight:'} ${_formatWeight(_asDouble(customer['net_weight']))}',
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 48, color: Colors.grey.shade500),
          const SizedBox(height: 12),
          Text(message, style: const TextStyle(color: Colors.grey)),
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

class _SalesTrendChart extends StatelessWidget {
  final List<Map<String, dynamic>> data;
  final String Function(num value) formatCurrency;
  final bool isArabic;
  final _ChartType chartType;

  const _SalesTrendChart({
    required this.data,
    required this.formatCurrency,
    required this.isArabic,
    required this.chartType,
  });

  double _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return const SizedBox.shrink();
    }

    final spots = <FlSpot>[];
    final labels = <int, String>{};

    for (var i = 0; i < data.length; i++) {
      final row = data[i];
      final value = _asDouble(row['net_value']);
      spots.add(FlSpot(i.toDouble(), value));
      labels[i] = row['period']?.toString() ?? '';
    }

    double maxY = spots.first.y;
    double minY = spots.first.y;
    for (final spot in spots) {
      maxY = math.max(maxY, spot.y);
      minY = math.min(minY, spot.y);
    }

    double range = maxY - minY;
    if (range.abs() < 1e-6) {
      maxY += 1;
      minY -= 1;
      range = maxY - minY;
    } else {
      final padding = range * 0.1;
      maxY += padding;
      minY -= padding;
      range = maxY - minY;
    }

    final gradientColors = <Color>[
      Colors.amber.shade600,
      Colors.orange.shade400,
    ];

    final bottomStep = math.max(1, (data.length / 6).ceil());
    final horizontalInterval = range <= 0 ? 1.0 : range / 5;

    Widget buildBottomTitle(double value, TitleMeta meta) {
      final index = value.round();
      if (index < 0 || index >= data.length || index % bottomStep != 0) {
        return const SizedBox.shrink();
      }
      final label = labels[index] ?? '';
      final angle = isArabic
          ? 0.6
          : -0.6; // rotate labels slightly to avoid overlap
      return Padding(
        padding: const EdgeInsets.only(top: 12),
        child: Transform.rotate(
          angle: angle,
          child: Text(
            label,
            style: const TextStyle(fontSize: 11),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    Widget buildLeftTitle(double value, TitleMeta meta) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Text(
          formatCurrency(value),
          style: const TextStyle(fontSize: 11),
          textAlign: TextAlign.right,
        ),
      );
    }

    final border = FlBorderData(
      show: true,
      border: Border(
        left: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
        bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
        top: BorderSide(color: Colors.grey.withValues(alpha: 0.08)),
        right: BorderSide(color: Colors.grey.withValues(alpha: 0.08)),
      ),
    );

    final grid = FlGridData(
      show: true,
      drawVerticalLine: false,
      horizontalInterval: horizontalInterval,
      getDrawingHorizontalLine: (value) =>
          FlLine(color: Colors.grey.withValues(alpha: 0.2), strokeWidth: 1),
    );

    switch (chartType) {
      case _ChartType.bar:
        final barGroups = List.generate(data.length, (index) {
          final value = spots[index].y;
          return BarChartGroupData(
            x: index,
            barRods: [
              BarChartRodData(
                toY: value,
                gradient: LinearGradient(colors: gradientColors),
                width: 18,
                borderRadius: const BorderRadius.all(Radius.circular(6)),
                backDrawRodData: BackgroundBarChartRodData(
                  show: true,
                  toY: 0,
                  color: Colors.grey.withValues(alpha: 0.06),
                ),
              ),
            ],
            showingTooltipIndicators: const [0],
          );
        });

        return BarChart(
          BarChartData(
            minY: minY,
            maxY: maxY,
            gridData: grid,
            borderData: border,
            alignment: BarChartAlignment.spaceAround,
            barTouchData: BarTouchData(
              enabled: true,
              touchTooltipData: BarTouchTooltipData(
                tooltipMargin: 12,
                tooltipPadding: const EdgeInsets.all(8),
                getTooltipItem: (group, groupIndex, rod, rodIndex) {
                  final period = labels[group.x.toInt()] ?? '';
                  final label = isArabic ? 'صافي المبيعات' : 'Net Sales';
                  final value = formatCurrency(rod.toY);
                  return BarTooltipItem(
                    '$period\n$label: $value',
                    const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  );
                },
              ),
            ),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: isArabic ? 56 : 72,
                  getTitlesWidget: buildBottomTitle,
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 88,
                  getTitlesWidget: buildLeftTitle,
                ),
              ),
            ),
            barGroups: barGroups,
          ),
        );
      case _ChartType.straightLine:
      case _ChartType.curvedLine:
        final isCurved = chartType == _ChartType.curvedLine;
        return LineChart(
          LineChartData(
            minY: minY,
            maxY: maxY,
            gridData: grid,
            borderData: border,
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              rightTitles: const AxisTitles(
                sideTitles: SideTitles(showTitles: false),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: isArabic ? 56 : 72,
                  getTitlesWidget: buildBottomTitle,
                ),
              ),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 88,
                  getTitlesWidget: buildLeftTitle,
                ),
              ),
            ),
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: isCurved,
                curveSmoothness: isCurved ? 0.25 : 0.0,
                barWidth: 3,
                gradient: LinearGradient(colors: gradientColors),
                dotData: FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, barData, index) =>
                      FlDotCirclePainter(
                        radius: 4,
                        color: Colors.white,
                        strokeColor: gradientColors.last,
                        strokeWidth: 2,
                      ),
                ),
                belowBarData: BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    colors: gradientColors
                        .map((color) => color.withValues(alpha: 0.15))
                        .toList(),
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                ),
              ),
            ],
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (touchedSpots) {
                  return touchedSpots
                      .map((spot) {
                        final index = spot.x.round();
                        if (index < 0 || index >= data.length) {
                          return null;
                        }
                        final period = data[index]['period'].toString();
                        final label = isArabic ? 'صافي المبيعات' : 'Net Sales';
                        final value = formatCurrency(spot.y);
                        return LineTooltipItem(
                          '$period\n$label: $value',
                          const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      })
                      .whereType<LineTooltipItem>()
                      .toList();
                },
              ),
            ),
          ),
        );
    }
  }
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
        color: metric.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: isArabic
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(metric.icon, color: metric.color),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  metric.label,
                  textAlign: isArabic ? TextAlign.right : TextAlign.left,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            metric.value,
            textAlign: isArabic ? TextAlign.right : TextAlign.left,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
