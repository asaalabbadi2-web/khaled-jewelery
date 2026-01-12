import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

class CustomerBalancesAgingReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const CustomerBalancesAgingReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<CustomerBalancesAgingReportScreen> createState() =>
      _CustomerBalancesAgingReportScreenState();
}

class _CustomerBalancesAgingReportScreenState
    extends State<CustomerBalancesAgingReportScreen> {
  bool _isLoading = true;
  String? _error;
  Map<String, dynamic> _report = {};

  DateTime _cutoffDate = DateTime.now();
  bool _includeZeroBalances = false;
  bool _includeUnposted = false;
  int? _customerGroupId;
  final TextEditingController _groupController = TextEditingController();

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  late NumberFormat _currencyFormat;
  final NumberFormat _weightFormat = NumberFormat('#,##0.000');

  @override
  void initState() {
    super.initState();
    final today = DateTime.now();
    _cutoffDate = DateTime(today.year, today.month, today.day);
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

  @override
  void dispose() {
    _groupController.dispose();
    super.dispose();
  }

  Future<void> _loadReport() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final response = await widget.api.getCustomerBalancesAgingReport(
        cutoffDate: _cutoffDate,
        includeZeroBalances: _includeZeroBalances,
        includeUnposted: _includeUnposted,
        customerGroupId: _customerGroupId,
      );
      if (!mounted) return;
      setState(() {
        _report = response;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _pickCutoffDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _cutoffDate,
      firstDate: DateTime(DateTime.now().year - 5),
      lastDate: DateTime(DateTime.now().year + 1),
      locale: widget.isArabic ? const Locale('ar') : const Locale('en'),
    );

    if (picked != null) {
      setState(
        () => _cutoffDate = DateTime(picked.year, picked.month, picked.day),
      );
      await _loadReport();
    }
  }

  void _updateGroupFilter(String value) {
    if (value.trim().isEmpty) {
      setState(() => _customerGroupId = null);
      return;
    }
    final parsed = int.tryParse(value.trim());
    setState(() => _customerGroupId = parsed);
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
            isArabic ? 'تقرير أعمار الذمم للعملاء' : 'Customer Balances Aging',
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
    final report = _report;
    final customers = List<Map<String, dynamic>>.from(
      report['customers'] ?? [],
    );
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
          _buildBucketChartCard(isArabic),
          const SizedBox(height: 16),
          _buildTopOverdueCard(isArabic),
          const SizedBox(height: 16),
          _buildCustomersTable(isArabic, customers),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final summary = _report['summary'] ?? {};
    final cutoffText = DateFormat('yyyy-MM-dd').format(_cutoffDate);

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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  isArabic ? 'خيارات التقرير' : 'Report Filters',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 16,
                  ),
                ),
                Text(
                  summary['total_customers'] != null
                      ? (isArabic
                            ? 'العملاء: ${summary['total_customers']}'
                            : 'Customers: ${summary['total_customers']}')
                      : '',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                OutlinedButton.icon(
                  onPressed: _pickCutoffDate,
                  icon: const Icon(Icons.event_available),
                  label: Text(
                    isArabic
                        ? 'تاريخ الترحيل: $cutoffText'
                        : 'Cutoff: $cutoffText',
                  ),
                ),
                FilterChip(
                  label: Text(
                    isArabic
                        ? 'إظهار الأرصدة الصفرية'
                        : 'Include zero balances',
                  ),
                  selected: _includeZeroBalances,
                  onSelected: (value) {
                    setState(() => _includeZeroBalances = value);
                    _loadReport();
                  },
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
                SizedBox(
                  width: 220,
                  child: TextField(
                    controller: _groupController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: isArabic
                          ? 'معرّف مجموعة العملاء'
                          : 'Customer group ID',
                      suffixIcon: _groupController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _groupController.clear();
                                _updateGroupFilter('');
                                _loadReport();
                              },
                            ),
                    ),
                    onChanged: (value) {
                      _updateGroupFilter(value);
                    },
                    onSubmitted: (_) => _loadReport(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(bool isArabic) {
    final summary = Map<String, dynamic>.from(_report['summary'] ?? {});
    if (summary.isEmpty) {
      return _buildEmptyState(
        icon: Icons.info_outline,
        message: isArabic ? 'لا توجد بيانات لعرضها.' : 'No data available.',
      );
    }

    final metrics = [
      _SummaryMetric(
        label: isArabic ? 'إجمالي الذمم (ر.س)' : 'Outstanding (Cash)',
        value: _formatCurrency(
          _asDouble(summary['total_outstanding_cash'] ?? 0),
        ),
        icon: Icons.payments,
        color: Colors.teal,
      ),
      _SummaryMetric(
        label: isArabic ? 'إجمالي الذمم (جم)' : 'Outstanding (Gold)',
        value: _formatWeight(
          _asDouble(summary['total_outstanding_weight'] ?? 0),
        ),
        icon: Icons.scale,
        color: Colors.amber.shade700,
      ),
      _SummaryMetric(
        label: isArabic ? 'أرصدة دائنة' : 'Credit balances',
        value: _formatCurrency(_asDouble(summary['credit_balances_cash'] ?? 0)),
        icon: Icons.account_balance,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'عدد العملاء' : 'Customer count',
        value: '${summary['total_customers'] ?? 0}',
        icon: Icons.people_alt,
        color: Colors.blue,
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

  Widget _buildBucketChartCard(bool isArabic) {
    final summary = Map<String, dynamic>.from(_report['summary'] ?? {});
    final bucketCash = Map<String, dynamic>.from(summary['bucket_cash'] ?? {});
    final bucketWeight = Map<String, dynamic>.from(
      summary['bucket_weight'] ?? {},
    );
    final bucketLabels = Map<String, dynamic>.from(_report['buckets'] ?? {});

    if (bucketCash.isEmpty && bucketWeight.isEmpty) {
      return _buildEmptyState(
        icon: Icons.bar_chart,
        message: isArabic
            ? 'لا يوجد توزيع أعمار لعرضه.'
            : 'No aging distribution to display.',
      );
    }

    final keys = bucketLabels.keys.isNotEmpty
        ? bucketLabels.keys.toList()
        : bucketCash.keys.toList();

    final groups = <BarChartGroupData>[];
    for (var i = 0; i < keys.length; i++) {
      final key = keys[i];
      final cashValue = _asDouble(bucketCash[key] ?? 0);
      final weightValue = _asDouble(bucketWeight[key] ?? 0);
      groups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              fromY: 0,
              toY: cashValue,
              width: 12,
              color: Colors.teal,
              borderRadius: BorderRadius.circular(4),
            ),
            BarChartRodData(
              fromY: 0,
              toY: weightValue,
              width: 12,
              color: Colors.amber.shade700,
              borderRadius: BorderRadius.circular(4),
            ),
          ],
          barsSpace: 8,
        ),
      );
    }

    final maxY = groups
        .expand((group) => group.barRods)
        .map((rod) => rod.toY)
        .fold<double>(0.0, (prev, value) => value > prev ? value : prev);

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
              isArabic ? 'توزيع الأعمار' : 'Aging distribution',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 280,
              child: BarChart(
                BarChartData(
                  maxY: maxY == 0 ? 1 : maxY * 1.2,
                  minY: 0,
                  alignment: BarChartAlignment.spaceAround,
                  gridData: const FlGridData(
                    show: true,
                    drawVerticalLine: false,
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 || index >= keys.length) {
                            return const SizedBox.shrink();
                          }
                          final label = bucketLabels[keys[index]];
                          final localized = label is Map
                              ? (isArabic
                                    ? (label['ar'] ?? '')
                                    : (label['en'] ?? ''))
                              : keys[index];
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              localized,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 11),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 64,
                        getTitlesWidget: (value, _) => Text(
                          _formatCurrency(value),
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
                  barGroups: groups,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 16,
              children: [
                _LegendChip(
                  color: Colors.teal,
                  label: isArabic ? 'القيمة (ر.س)' : 'Cash',
                ),
                _LegendChip(
                  color: Colors.amber.shade700,
                  label: isArabic ? 'الوزن (جم)' : 'Gold weight',
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopOverdueCard(bool isArabic) {
    final topCustomers = List<Map<String, dynamic>>.from(
      _report['top_overdue_customers'] ?? [],
    );

    if (topCustomers.isEmpty) {
      return Card(
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: _buildEmptyState(
          icon: Icons.verified,
          message: isArabic
              ? 'لا يوجد عملاء متأخرين.'
              : 'No overdue customers.',
        ),
      );
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
              isArabic ? 'أكثر العملاء تراكماً' : 'Top overdue customers',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            ...topCustomers.map((customer) {
              final over90 = customer['buckets']?['over_90'] ?? {};
              final over90Cash = _formatCurrency(
                _asDouble(over90['cash'] ?? 0),
              );
              final outstandingCash = _formatCurrency(
                _asDouble(customer['outstanding_cash'] ?? 0),
              );
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: CircleAvatar(
                  backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
                  child: const Icon(Icons.warning, color: Colors.redAccent),
                ),
                title: Text(
                  customer['customer_name'] ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  isArabic
                      ? 'أكثر من 90 يوم: $over90Cash'
                      : '90+ days: $over90Cash',
                ),
                trailing: Text(outstandingCash),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildCustomersTable(
    bool isArabic,
    List<Map<String, dynamic>> customers,
  ) {
    if (customers.isEmpty) {
      return _buildEmptyState(
        icon: Icons.table_chart,
        message: isArabic ? 'لا توجد بيانات عملاء' : 'No customer data.',
      );
    }

    final columns = [
      DataColumn(label: Text(isArabic ? 'العميل' : 'Customer')),
      DataColumn(label: Text(isArabic ? 'الرصيد (ر.س)' : 'Outstanding (cash)')),
      DataColumn(label: Text(isArabic ? 'الرصيد (جم)' : 'Outstanding (g)')),
      DataColumn(label: Text(isArabic ? '0-30' : '0-30')),
      DataColumn(label: Text(isArabic ? '31-60' : '31-60')),
      DataColumn(label: Text(isArabic ? '61-90' : '61-90')),
      DataColumn(label: Text(isArabic ? '90+' : '90+')),
      DataColumn(label: Text(isArabic ? 'متوسط الأيام' : 'Avg days')),
    ];

    final rows = customers.map((customer) {
      final buckets = Map<String, dynamic>.from(customer['buckets'] ?? {});
      return DataRow(
        cells: [
          DataCell(
            Column(
              crossAxisAlignment: isArabic
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  customer['customer_name'] ?? '',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  customer['customer_code'] ?? '',
                  style: const TextStyle(color: Colors.grey, fontSize: 12),
                ),
              ],
            ),
          ),
          DataCell(
            Text(_formatCurrency(_asDouble(customer['outstanding_cash'] ?? 0))),
          ),
          DataCell(
            Text(_formatWeight(_asDouble(customer['outstanding_weight'] ?? 0))),
          ),
          DataCell(
            Text(_formatCurrency(_asDouble(buckets['current']?['cash'] ?? 0))),
          ),
          DataCell(
            Text(
              _formatCurrency(_asDouble(buckets['days_31_60']?['cash'] ?? 0)),
            ),
          ),
          DataCell(
            Text(
              _formatCurrency(_asDouble(buckets['days_61_90']?['cash'] ?? 0)),
            ),
          ),
          DataCell(
            Text(_formatCurrency(_asDouble(buckets['over_90']?['cash'] ?? 0))),
          ),
          DataCell(Text('${customer['average_days_overdue'] ?? 0}')),
        ],
      );
    }).toList();

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.all(16),
        child: DataTable(columns: columns, rows: rows),
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
