import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

class SalesByCustomerReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const SalesByCustomerReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<SalesByCustomerReportScreen> createState() => _SalesByCustomerReportScreenState();
}

class _SalesByCustomerReportScreenState extends State<SalesByCustomerReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = false;
  String? _error;

  DateTimeRange? _selectedRange;
  bool _includeUnposted = false;
  int _limit = 25;
  String _orderBy = 'net_value';
  bool _ascending = false;

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  int _mainKarat = 21;

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;

  static const List<int> _limitOptions = [5, 10, 25, 50, 100];
  static const List<String> _orderOptions = [
    'net_value',
    'sales_value',
    'returns_value',
    'documents',
    'net_weight',
    'last_invoice_date',
  ];

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day).subtract(const Duration(days: 29));
    final end = DateTime(today.year, today.month, today.day);
    _selectedRange = DateTimeRange(start: start, end: end);
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

    if (settings.currencySymbol != _currencySymbol ||
        settings.decimalPlaces != _currencyDecimals ||
        settings.mainKarat != _mainKarat) {
      setState(() {
        _currencySymbol = settings.currencySymbol;
        _currencyDecimals = settings.decimalPlaces;
        _mainKarat = settings.mainKarat;
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
      final result = await widget.api.getSalesByCustomerReport(
        startDate: _selectedRange?.start,
        endDate: _selectedRange?.end,
        includeUnposted: _includeUnposted,
        limit: _limit,
        orderBy: _orderBy,
        ascending: _ascending,
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
    final initialRange = _selectedRange ??
        DateTimeRange(
          start: now.subtract(const Duration(days: 29)),
          end: now,
        );

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

  String _localizedOrderLabel(String key) {
    final isArabic = widget.isArabic;
    switch (key) {
      case 'net_value':
        return isArabic ? 'صافي المبيعات' : 'Net Sales';
      case 'sales_value':
        return isArabic ? 'إجمالي المبيعات' : 'Gross Sales';
      case 'returns_value':
        return isArabic ? 'المرتجعات' : 'Returns';
      case 'documents':
        return isArabic ? 'عدد المستندات' : 'Documents';
      case 'net_weight':
        return isArabic ? 'صافي الوزن' : 'Net Weight';
      case 'last_invoice_date':
        return isArabic ? 'آخر حركة' : 'Last Activity';
      default:
        return key;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'تقرير المبيعات حسب العميل' : 'Sales by Customer'),
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
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          _buildFiltersCard(isArabic),
          const SizedBox(height: 16),
          _buildSummaryCard(isArabic),
          const SizedBox(height: 16),
          _buildChartCard(isArabic),
          const SizedBox(height: 16),
          _buildTableCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final rangeText = _selectedRange == null
        ? (isArabic ? 'كل الفترات' : 'All time')
        : '${DateFormat('yyyy-MM-dd').format(_selectedRange!.start)} - ${DateFormat('yyyy-MM-dd').format(_selectedRange!.end)}';

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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
                FilterChip(
                  label: Text(isArabic ? 'تضمين غير المرحلة' : 'Include Unposted'),
                  selected: _includeUnposted,
                  onSelected: (value) {
                    setState(() => _includeUnposted = value);
                    _loadReport();
                  },
                ),
                Wrap(
                  spacing: 8,
                  children: _limitOptions.map((option) {
                    final selected = _limit == option;
                    return ChoiceChip(
                      label: Text('${isArabic ? 'أعلى' : 'Top'} $option'),
                      selected: selected,
                      onSelected: (value) {
                        if (!value || _limit == option) return;
                        setState(() => _limit = option);
                        _loadReport();
                      },
                    );
                  }).toList(),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: _orderBy,
                      items: _orderOptions
                          .map(
                            (option) => DropdownMenuItem(
                              value: option,
                              child: Text(_localizedOrderLabel(option)),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null || value == _orderBy) return;
                        setState(() => _orderBy = value);
                        _loadReport();
                      },
                    ),
                    IconButton(
                      tooltip: isArabic ? 'تغيير الترتيب' : 'Toggle order',
                      icon: Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward),
                      onPressed: () {
                        setState(() => _ascending = !_ascending);
                        _loadReport();
                      },
                    ),
                  ],
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
        icon: Icons.info_outline,
        message: isArabic ? 'لا توجد بيانات للعرض.' : 'No data available.',
      );
    }

    final metrics = [
      _SummaryMetric(
        label: isArabic ? 'عدد العملاء' : 'Customers',
        value: '${summary['customer_count'] ?? 0}',
        icon: Icons.people,
        color: Colors.blue,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي المبيعات' : 'Net Sales',
        value: _formatCurrency(_asDouble(summary['net_value'])),
        icon: Icons.trending_up,
        color: Colors.green,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي المستندات' : 'Documents',
        value: '${summary['documents'] ?? 0}',
        icon: Icons.receipt_long,
        color: Colors.teal,
      ),
      _SummaryMetric(
        label: isArabic ? 'متوسط الفاتورة' : 'Avg Invoice',
        value: _formatCurrency(_asDouble(summary['average_invoice_value'])),
        icon: Icons.payments,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'صافي الوزن' : 'Net Weight',
        value: '${_formatWeight(_asDouble(summary['net_weight']))} (عيار $_mainKarat)',
        icon: Icons.scale,
        color: Colors.purple,
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

  Widget _buildChartCard(bool isArabic) {
    final customers = List<Map<String, dynamic>>.from(
      _report?['customers'] as List<dynamic>? ?? const [],
    );

    if (customers.isEmpty) {
      return const SizedBox.shrink();
    }

    final slice = customers.take(10).toList();
    final hasValues = slice.any((row) => _asDouble(row['net_value']).abs() > 0);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'أعلى العملاء (قيمة)' : 'Top Customers by Net Sales',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            if (hasValues)
              SizedBox(
                height: 280,
                child: _TopCustomersChart(
                  customers: slice,
                  isArabic: isArabic,
                  formatCurrency: _formatCurrency,
                ),
              )
            else
              _buildEmptyState(
                icon: Icons.bar_chart,
                message: isArabic ? 'لا توجد قيم موجبة للعرض.' : 'No positive values to show.',
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTableCard(bool isArabic) {
    final customers = List<Map<String, dynamic>>.from(
      _report?['customers'] as List<dynamic>? ?? const [],
    );

    if (customers.isEmpty) {
      return _buildEmptyState(
        icon: Icons.group_outlined,
        message: isArabic ? 'لا توجد بيانات عملاء.' : 'No customer data available.',
      );
    }

    final dateFormat = DateFormat('yyyy-MM-dd');

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'قائمة العملاء' : 'Customers List',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'الترتيب' : '#')),
                  DataColumn(label: Text(isArabic ? 'العميل' : 'Customer')),
                  DataColumn(label: Text(isArabic ? 'المستندات' : 'Documents')),
                  DataColumn(label: Text(isArabic ? 'إجمالي المبيعات' : 'Sales')),
                  DataColumn(label: Text(isArabic ? 'المرتجعات' : 'Returns')),
                  DataColumn(label: Text(isArabic ? 'صافي المبيعات' : 'Net Sales')),
                  DataColumn(label: Text(isArabic ? 'صافي الوزن' : 'Net Weight')),
                  DataColumn(label: Text(isArabic ? 'متوسط الفاتورة' : 'Avg Invoice')),
                  DataColumn(label: Text(isArabic ? 'رصيد نقدي' : 'Cash Balance')),
                  DataColumn(label: Text(isArabic ? 'رصيد ذهب' : 'Gold Balance')),
                  DataColumn(label: Text(isArabic ? 'آخر حركة' : 'Last Activity')),
                ],
                rows: customers.map((customer) {
                  final lastDate = customer['last_invoice_date'];
                  final formattedDate = lastDate == null
                      ? '-'
                      : dateFormat.format(DateTime.parse(lastDate));
                  return DataRow(
                    cells: [
                      DataCell(Text('${customer['rank']}')),
                      DataCell(Text(
                        customer['customer_code'] != null
                            ? '${customer['customer_name']} (${customer['customer_code']})'
                            : customer['customer_name']?.toString() ?? '-',
                      )),
                      DataCell(Text('${customer['documents'] ?? 0}')),
                      DataCell(Text(_formatCurrency(_asDouble(customer['sales_value'])))),
                      DataCell(Text(_formatCurrency(_asDouble(customer['returns_value'])))),
                      DataCell(Text(_formatCurrency(_asDouble(customer['net_value'])))),
                      DataCell(Text(_formatWeight(_asDouble(customer['net_weight'])))),
                      DataCell(Text(_formatCurrency(_asDouble(customer['average_invoice_value'])))),
                      DataCell(Text(_formatCurrency(_asDouble(customer['balance_cash'])))),
                      DataCell(Text(_formatWeight(_asDouble(customer['balance_gold_main_karat'])))),
                      DataCell(Text(formattedDate)),
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
        crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
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

class _TopCustomersChart extends StatelessWidget {
  final List<Map<String, dynamic>> customers;
  final bool isArabic;
  final String Function(num value) formatCurrency;

  const _TopCustomersChart({
    required this.customers,
    required this.isArabic,
    required this.formatCurrency,
  });

  double _asDouble(dynamic value) {
    if (value is int) return value.toDouble();
    if (value is num) return value.toDouble();
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    if (customers.isEmpty) {
      return const SizedBox.shrink();
    }

    final data = customers.asMap().entries.map((entry) {
      final index = entry.key;
      final row = entry.value;
      final value = _asDouble(row['net_value']);
      final label = row['customer_code'] != null
          ? '${row['customer_name']} (${row['customer_code']})'
          : row['customer_name']?.toString() ?? '';
      return _ChartPoint(index: index, label: label, value: value);
    }).toList();

    final maxY = data.fold<double>(0, (prev, point) => math.max(prev, point.value.abs()));
    final interval = maxY <= 0 ? 1.0 : maxY / 4;

    return BarChart(
      BarChartData(
        maxY: maxY <= 0 ? 1.0 : maxY * 1.1,
        minY: 0,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: interval <= 0 ? 1.0 : interval,
          getDrawingHorizontalLine: (value) => FlLine(
            color: Colors.grey.withValues(alpha: 0.2),
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(
          show: true,
          border: Border(
            left: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
            bottom: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
            top: BorderSide(color: Colors.grey.withValues(alpha: 0.08)),
            right: BorderSide(color: Colors.grey.withValues(alpha: 0.08)),
          ),
        ),
        titlesData: FlTitlesData(
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 80,
              getTitlesWidget: (value, meta) => SideTitleWidget(
                axisSide: meta.axisSide,
                space: 12,
                child: Text(
                  formatCurrency(value),
                  style: const TextStyle(fontSize: 11),
                  textAlign: TextAlign.right,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: isArabic ? 60 : 72,
              getTitlesWidget: (value, meta) {
                final index = value.round();
                if (index < 0 || index >= data.length) {
                  return const SizedBox.shrink();
                }
                final point = data[index];
                return SideTitleWidget(
                  axisSide: meta.axisSide,
                  angle: isArabic ? 0.6 : -0.6,
                  space: 12,
                  child: SizedBox(
                    width: 120,
                    child: Text(
                      point.label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                      textAlign: TextAlign.center,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: data
            .map(
              (point) => BarChartGroupData(
                x: point.index,
                barRods: [
                  BarChartRodData(
                    toY: point.value,
                    gradient: LinearGradient(
                      colors: [
                        Colors.amber.shade600,
                        Colors.orange.shade400,
                      ],
                    ),
                    width: 20,
                    borderRadius: const BorderRadius.all(Radius.circular(8)),
                  ),
                ],
              ),
            )
            .toList(),
        barTouchData: BarTouchData(
          enabled: true,
          touchTooltipData: BarTouchTooltipData(
            tooltipPadding: const EdgeInsets.all(8),
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final point = data[group.x.toInt()];
              final label = isArabic ? 'صافي المبيعات' : 'Net Sales';
              return BarTooltipItem(
                '${point.label}\n$label: ${formatCurrency(rod.toY)}',
                const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ChartPoint {
  final int index;
  final String label;
  final double value;

  const _ChartPoint({
    required this.index,
    required this.label,
    required this.value,
  });
}
