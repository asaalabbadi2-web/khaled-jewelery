import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../api_service.dart';

class LowStockReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const LowStockReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<LowStockReportScreen> createState() => _LowStockReportScreenState();
}

class _LowStockReportScreenState extends State<LowStockReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = true;
  String? _error;

  final Set<num> _selectedKarats = <num>{};
  bool _includeZeroStock = false;
  bool _includeUnposted = false;
  int? _officeId;
  double _thresholdQuantity = 2;
  double _thresholdWeight = 15;
  int _limit = 150;
  String _sortBy = 'severity';
  bool _ascending = false;

  final List<num> _karatOptions = [18, 21, 22, 24];
  final List<int> _limitOptions = [25, 50, 75, 100, 150, 200, 300];
  final Map<String, String> _sortLabelsAr = {
    'severity': 'الأكثر خطورة',
    'quantity': 'الكمية المتاحة',
    'weight': 'الوزن (عيار رئيسي)',
    'name': 'الاسم',
  };
  final Map<String, String> _sortLabelsEn = {
    'severity': 'Severity',
    'quantity': 'Quantity',
    'weight': 'Weight (Main Karat)',
    'name': 'Name',
  };

  final TextEditingController _officeController = TextEditingController();
  final TextEditingController _thresholdQtyController = TextEditingController();
  final TextEditingController _thresholdWeightController = TextEditingController();

  final NumberFormat _quantityFormat = NumberFormat('#,##0.##');
  final NumberFormat _weightFormat = NumberFormat('#,##0.000');

  @override
  void initState() {
    super.initState();
    _thresholdQtyController.text = _thresholdQuantity.toStringAsFixed(1);
    _thresholdWeightController.text = _thresholdWeight.toStringAsFixed(1);
    _loadReport();
  }

  @override
  void dispose() {
    _officeController.dispose();
    _thresholdQtyController.dispose();
    _thresholdWeightController.dispose();
    super.dispose();
  }

  Future<void> _loadReport() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final result = await widget.api.getLowStockReport(
        includeZeroStock: _includeZeroStock,
        includeUnposted: _includeUnposted,
        karats: _selectedKarats.isEmpty ? null : _selectedKarats.toList(),
        officeId: _officeId,
        thresholdQuantity: _thresholdQuantity,
        thresholdWeight: _thresholdWeight,
        limit: _limit,
        sortBy: _sortBy,
        ascending: _ascending,
      );
      if (!mounted) return;
      setState(() => _report = result);
    } catch (err) {
      if (!mounted) return;
      setState(() => _error = err.toString());
    } finally {
      if (!mounted) return;
      setState(() => _isLoading = false);
    }
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0;
    return 0;
  }

  List<Map<String, dynamic>> get _items {
    final raw = _report?['items'];
    if (raw is List) return raw.cast<Map<String, dynamic>>();
    return const [];
  }

  Map<String, dynamic> get _summary {
    final raw = _report?['summary'];
    if (raw is Map<String, dynamic>) return raw;
    return const {};
  }

  Widget _buildStatusChip(String status, bool isArabic) {
    Color color;
    String label;
    switch (status) {
      case 'critical':
        color = Colors.red.shade600;
        label = isArabic ? 'حرج' : 'Critical';
        break;
      case 'low':
        color = Colors.orange.shade600;
        label = isArabic ? 'منخفض' : 'Low';
        break;
      default:
        color = Colors.green.shade600;
        label = isArabic ? 'مستقر' : 'OK';
    }
    return Chip(
      backgroundColor: color.withValues(alpha: 0.15),
      label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }

  void _applyThresholds() {
    final qty = double.tryParse(_thresholdQtyController.text.replaceAll(',', '.'));
    final weight = double.tryParse(_thresholdWeightController.text.replaceAll(',', '.'));
    setState(() {
      if (qty != null) {
        _thresholdQuantity = qty.clamp(0, 1000);
        _thresholdQtyController.text = _thresholdQuantity.toStringAsFixed(1);
      }
      if (weight != null) {
        _thresholdWeight = weight.clamp(0, 2000);
        _thresholdWeightController.text = _thresholdWeight.toStringAsFixed(1);
      }
    });
    _loadReport();
  }

  void _applyOfficeFilter() {
    final trimmed = _officeController.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _officeId = null);
      _loadReport();
      return;
    }
    final parsed = int.tryParse(trimmed);
    setState(() => _officeId = parsed);
    _loadReport();
  }

  String _formatQuantity(num value) => _quantityFormat.format(value);

  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  Widget _buildErrorState(bool isArabic) {
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
          const SizedBox(height: 12),
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
            label: Text(isArabic ? 'إعادة المحاولة' : 'Try again'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'تقرير الأصناف منخفضة المخزون' : 'Low Stock Items'),
          actions: [
            IconButton(
              tooltip: isArabic ? 'تحديث' : 'Refresh',
              icon: const Icon(Icons.refresh),
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
          _buildCriticalChartCard(isArabic),
          const SizedBox(height: 16),
          _buildItemsTable(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final limitItems = _limitOptions
        .map(
          (value) => DropdownMenuItem<int>(
            value: value,
            child: Text(isArabic ? 'أعلى $value' : 'Top $value'),
          ),
        )
        .toList();

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
                Wrap(
                  spacing: 8,
                  children: _karatOptions.map((karat) {
                    final selected = _selectedKarats.contains(karat);
                    return FilterChip(
                      label: Text(isArabic ? 'عيار $karat' : '${karat}K'),
                      selected: selected,
                      onSelected: (value) {
                        setState(() {
                          if (value) {
                            _selectedKarats.add(karat);
                          } else {
                            _selectedKarats.remove(karat);
                          }
                        });
                        _loadReport();
                      },
                    );
                  }).toList(),
                ),
                FilterChip(
                  label: Text(isArabic ? 'تضمين المخزون الصفري' : 'Include zero stock'),
                  selected: _includeZeroStock,
                  onSelected: (value) {
                    setState(() => _includeZeroStock = value);
                    _loadReport();
                  },
                ),
                FilterChip(
                  label: Text(isArabic ? 'تضمين غير المرحلة' : 'Include unposted'),
                  selected: _includeUnposted,
                  onSelected: (value) {
                    setState(() => _includeUnposted = value);
                    _loadReport();
                  },
                ),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _officeController,
                    keyboardType: TextInputType.number,
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: isArabic ? 'معرّف المكتب' : 'Office ID',
                      suffixIcon: _officeController.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _officeController.clear();
                                _applyOfficeFilter();
                              },
                            ),
                    ),
                    onSubmitted: (_) => _applyOfficeFilter(),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _thresholdQtyController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: isArabic ? 'حد الكمية' : 'Qty threshold',
                    ),
                    onSubmitted: (_) => _applyThresholds(),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: TextField(
                    controller: _thresholdWeightController,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    textDirection: TextDirection.ltr,
                    decoration: InputDecoration(
                      labelText: isArabic ? 'حد الوزن (جم)' : 'Weight threshold (g)',
                    ),
                    onSubmitted: (_) => _applyThresholds(),
                  ),
                ),
                DropdownButton<int>(
                  value: _limit,
                  items: limitItems,
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _limit = value);
                    _loadReport();
                  },
                ),
                DropdownButton<String>(
                  value: _sortBy,
                  items: _sortLabelsAr.keys
                      .map(
                        (key) => DropdownMenuItem<String>(
                          value: key,
                          child: Text(isArabic ? _sortLabelsAr[key]! : _sortLabelsEn[key]!),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _sortBy = value);
                    _loadReport();
                  },
                ),
                IconButton(
                  tooltip: isArabic ? 'تغيير ترتيب الفرز' : 'Toggle sort order',
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
      ),
    );
  }

  Widget _buildSummaryCard(bool isArabic) {
    final summary = _summary;
    if (summary.isEmpty) {
      return _buildEmptyState(
        icon: Icons.inventory_2,
        message: isArabic ? 'لا توجد بيانات متاحة' : 'No data available',
      );
    }

    final metrics = [
      _SummaryMetric(
        label: isArabic ? 'الأصناف المتأثرة' : 'Items below threshold',
        value: '${summary['items_below_threshold'] ?? 0}',
        icon: Icons.warning,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'الأصناف الحرجة' : 'Critical items',
        value: '${summary['critical_items'] ?? 0}',
        icon: Icons.notification_important,
        color: Colors.redAccent,
      ),
      _SummaryMetric(
        label: isArabic ? 'نقص الكمية' : 'Shortage Qty',
        value: _formatQuantity(_asDouble(summary['total_shortage_quantity'] ?? 0)),
        icon: Icons.scale,
        color: Colors.blueAccent,
      ),
      _SummaryMetric(
        label: isArabic ? 'نقص الوزن (جم)' : 'Shortage weight (g)',
        value: _formatWeight(_asDouble(summary['total_shortage_weight'] ?? 0)),
        icon: Icons.fitness_center,
        color: Colors.amber.shade700,
      ),
    ];

    final avgDays = summary['average_days_since_movement'];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Wrap(
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
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              children: [
                Chip(
                  avatar: const Icon(Icons.inventory_outlined),
                  label: Text(
                    isArabic
                        ? 'الأصناف المحللة: ${summary['items_considered'] ?? 0}'
                        : 'Items analyzed: ${summary['items_considered'] ?? 0}',
                  ),
                ),
                if (avgDays != null)
                  Chip(
                    avatar: const Icon(Icons.history_toggle_off),
                    label: Text(
                      isArabic
                          ? 'متوسط الأيام دون حركة: $avgDays'
                          : 'Avg days since movement: $avgDays',
                    ),
                  ),
                if (summary['generated_at'] != null)
                  Chip(
                    avatar: const Icon(Icons.schedule_outlined),
                    label: Text(
                      isArabic
                          ? 'تم التحديث: ${summary['generated_at']}'
                          : 'Generated: ${summary['generated_at']}',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCriticalChartCard(bool isArabic) {
    final items = _items.take(8).toList();
    if (items.isEmpty) {
      return _buildEmptyState(
        icon: Icons.bar_chart,
        message: isArabic ? 'لا توجد أصناف حرجة لعرضها' : 'No critical items to display',
      );
    }

    final maxShortage = items.fold<double>(0, (max, item) {
      final shortage = _asDouble(item['shortage_weight']);
      return math.max(max, shortage);
    });

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'أكثر الأصناف خطورة' : 'Most critical items',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 260,
              child: BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  maxY: maxShortage == 0 ? 1 : maxShortage * 1.2,
                  gridData: FlGridData(show: true, horizontalInterval: maxShortage == 0 ? 1 : maxShortage / 4),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
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
                          if (index < 0 || index >= items.length) {
                            return const SizedBox.shrink();
                          }
                          final item = items[index];
                          final code = item['item_code'] ?? '';
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              '$code',
                              style: const TextStyle(fontSize: 10),
                              textAlign: TextAlign.center,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < items.length; i++)
                      BarChartGroupData(
                        x: i,
                        barRods: [
                          BarChartRodData(
                            fromY: 0,
                            toY: _asDouble(items[i]['shortage_weight']),
                            width: 18,
                            color: Colors.amber.shade800,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: items.map((item) {
                final shortageWeight = _formatWeight(_asDouble(item['shortage_weight']));
                final name = item['name'] ?? item['item_code'] ?? '';
                return Chip(
                  avatar: const Icon(Icons.flag, size: 18),
                  label: Text(
                    isArabic
                        ? '$name · نقص $shortageWeight'
                        : '$name · shortage $shortageWeight',
                  ),
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItemsTable(bool isArabic) {
    final items = _items;
    if (items.isEmpty) {
      return _buildEmptyState(
        icon: Icons.table_chart,
        message: isArabic ? 'لا توجد أصناف مطابقة للمعايير الحالية' : 'No items match the selected filters',
      );
    }

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'جدول الأصناف' : 'Items table',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                headingTextStyle: const TextStyle(fontWeight: FontWeight.bold),
                columns: [
                  DataColumn(label: Text(isArabic ? 'الصنف' : 'Item')),
                  DataColumn(label: Text(isArabic ? 'العيار' : 'Karat')),
                  DataColumn(label: Text(isArabic ? 'كمية متاحة' : 'Available qty')),
                  DataColumn(label: Text(isArabic ? 'وزن متاح' : 'Available weight')),
                  DataColumn(label: Text(isArabic ? 'نقص الكمية' : 'Shortage qty')),
                  DataColumn(label: Text(isArabic ? 'نقص الوزن' : 'Shortage weight')),
                  DataColumn(label: Text(isArabic ? 'الحالة' : 'Status')),
                  DataColumn(label: Text(isArabic ? 'أيام بلا حركة' : 'Days no movement')),
                ],
                rows: items.map((item) {
                  final status = (item['status'] ?? '').toString();
                  final lastMovement = item['days_since_movement'];
                  return DataRow(
                    cells: [
                      DataCell(
                        Column(
                          crossAxisAlignment:
                              isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(item['name'] ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(
                              item['item_code'] ?? '',
                              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      DataCell(Text(item['karat']?.toString() ?? '-')),
                      DataCell(Text(_formatQuantity(_asDouble(item['available_quantity'])))),
                      DataCell(Text(_formatWeight(_asDouble(item['available_weight_main'])))),
                      DataCell(Text(_formatQuantity(_asDouble(item['shortage_quantity'])))),
                      DataCell(Text(_formatWeight(_asDouble(item['shortage_weight'])))),
                      DataCell(_buildStatusChip(status, isArabic)),
                      DataCell(Text(lastMovement != null ? '$lastMovement' : '-')),
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
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
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
    final alignment = isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: metric.color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: alignment,
        children: [
          Row(
            mainAxisAlignment:
                isArabic ? MainAxisAlignment.end : MainAxisAlignment.start,
            children: [
              CircleAvatar(
                backgroundColor: metric.color.withValues(alpha: 0.2),
                child: Icon(metric.icon, color: metric.color),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            metric.label,
            style: TextStyle(color: Colors.grey.shade700),
          ),
          const SizedBox(height: 6),
          Text(
            metric.value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
