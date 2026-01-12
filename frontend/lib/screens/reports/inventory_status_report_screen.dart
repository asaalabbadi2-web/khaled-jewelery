import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

class InventoryStatusReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const InventoryStatusReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<InventoryStatusReportScreen> createState() =>
      _InventoryStatusReportScreenState();
}

class _InventoryStatusReportScreenState
    extends State<InventoryStatusReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = false;
  String? _error;

  final Set<num> _selectedKarats = <num>{};
  bool _includeZeroStock = false;
  bool _includeUnposted = false;
  int? _limit = 100;
  String _orderBy = 'market_value';
  bool _ascending = false;
  int _slowDays = 45;

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  int _mainKarat = 21;

  late NumberFormat _currencyFormat;
  late NumberFormat _weightFormat;

  final List<int> _limitOptions = [25, 50, 100, 200, 500];
  final List<int> _slowDaysOptions = [15, 30, 45, 60, 90, 120];
  final List<num> _karatOptions = [18, 21, 22, 24];

  static const List<String> _orderOptions = [
    'market_value',
    'effective_weight_main_karat',
    'effective_stock_quantity',
    'valuation_gap',
    'item_code',
    'item_name',
    'days_since_movement',
    'documents',
    'status',
  ];

  @override
  void initState() {
    super.initState();
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
      final result = await widget.api.getInventoryStatusReport(
        karats: _selectedKarats.isEmpty ? null : _selectedKarats.toList(),
        includeZeroStock: _includeZeroStock,
        includeUnposted: _includeUnposted,
        limit: _limit,
        orderBy: _orderBy,
        ascending: _ascending,
        slowDays: _slowDays,
      );
      if (!mounted) return;
      setState(() {
        _report = result;
      });
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _error = err.toString();
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  String _formatCurrency(num value) => _currencyFormat.format(value);

  String _formatWeight(num value) => '${_weightFormat.format(value)} جم';

  String _localizedOrderLabel(String key, bool isArabic) {
    switch (key) {
      case 'market_value':
        return isArabic ? 'القيمة السوقية' : 'Market Value';
      case 'effective_weight_main_karat':
        return isArabic ? 'الوزن (عيار رئيسي)' : 'Weight (Main Karat)';
      case 'effective_stock_quantity':
        return isArabic ? 'الكمية المتاحة' : 'Stock Quantity';
      case 'valuation_gap':
        return isArabic ? 'فرق التقييم' : 'Valuation Gap';
      case 'item_code':
        return isArabic ? 'كود الصنف' : 'Item Code';
      case 'item_name':
        return isArabic ? 'اسم الصنف' : 'Item Name';
      case 'days_since_movement':
        return isArabic ? 'أيام منذ آخر حركة' : 'Days Since Movement';
      case 'documents':
        return isArabic ? 'عدد المستندات' : 'Documents';
      case 'status':
        return isArabic ? 'الحالة' : 'Status';
      default:
        return key;
    }
  }

  List<Map<String, dynamic>> get _items {
    final raw = _report?['items'];
    if (raw is List) {
      return raw.cast<Map<String, dynamic>>();
    }
    return const [];
  }

  Map<String, dynamic> get _summary {
    final raw = _report?['summary'];
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    return const {};
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'تقرير حالة المخزون' : 'Inventory Status'),
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
          _buildChartCard(isArabic),
          const SizedBox(height: 16),
          _buildTableCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildFiltersCard(bool isArabic) {
    final chips = _karatOptions.map((karat) {
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
    }).toList();

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
                Wrap(spacing: 8, children: chips),
                FilterChip(
                  label: Text(
                    isArabic ? 'تضمين المخزون الصفري' : 'Include Zero Stock',
                  ),
                  selected: _includeZeroStock,
                  onSelected: (value) {
                    setState(() => _includeZeroStock = value);
                    _loadReport();
                  },
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
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<int?>(
                      value: _limit,
                      hint: Text(isArabic ? 'عرض الكل' : 'Show all'),
                      items: [
                        const DropdownMenuItem<int?>(
                          value: null,
                          child: Text('∞'),
                        ),
                        ..._limitOptions.map(
                          (value) => DropdownMenuItem<int?>(
                            value: value,
                            child: Text(
                              isArabic ? 'أعلى $value' : 'Top $value',
                            ),
                          ),
                        ),
                      ],
                      onChanged: (value) {
                        setState(() => _limit = value);
                        _loadReport();
                      },
                    ),
                    const SizedBox(width: 12),
                    DropdownButton<int>(
                      value: _slowDays,
                      items: _slowDaysOptions
                          .map(
                            (value) => DropdownMenuItem<int>(
                              value: value,
                              child: Text(
                                isArabic
                                    ? 'بطيء بعد $value يوم'
                                    : 'Slow after $value d',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _slowDays = value);
                        _loadReport();
                      },
                    ),
                  ],
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButton<String>(
                      value: _orderBy,
                      items: _orderOptions
                          .map(
                            (value) => DropdownMenuItem<String>(
                              value: value,
                              child: Text(
                                _localizedOrderLabel(value, isArabic),
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _orderBy = value);
                        _loadReport();
                      },
                    ),
                    IconButton(
                      tooltip: isArabic ? 'تغيير الترتيب' : 'Toggle order',
                      icon: Icon(
                        _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                      ),
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
    final summary = _summary;
    if (summary.isEmpty) {
      return _buildEmptyState(
        isArabic ? 'لا توجد بيانات للعرض.' : 'No data available.',
        Icons.inventory_2,
      );
    }

    final priceInfo = summary['price_reference'] as Map<String, dynamic>?;
    final cards = [
      _SummaryMetric(
        label: isArabic ? 'عدد الأصناف' : 'Items',
        value: '${summary['items_considered'] ?? summary['items_total'] ?? 0}',
        icon: Icons.category,
        color: Colors.blue,
      ),
      _SummaryMetric(
        label: isArabic ? 'أصناف متاحة' : 'In Stock',
        value: '${summary['items_in_stock'] ?? 0}',
        icon: Icons.inventory,
        color: Colors.green,
      ),
      _SummaryMetric(
        label: isArabic ? 'الوزن المتاح' : 'Available Weight',
        value: _formatWeight(
          _asDouble(summary['total_effective_weight_main_karat']),
        ),
        icon: Icons.scale,
        color: Colors.orange,
      ),
      _SummaryMetric(
        label: isArabic ? 'القيمة السوقية' : 'Market Value',
        value: _formatCurrency(_asDouble(summary['total_market_value'])),
        icon: Icons.account_balance_wallet,
        color: Colors.purple,
      ),
      _SummaryMetric(
        label: isArabic ? 'أصناف حركة بطيئة' : 'Slow Moving',
        value: '${summary['slow_moving_items'] ?? 0}',
        icon: Icons.timer,
        color: Colors.redAccent,
      ),
    ];

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
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: cards
                  .map(
                    (metric) => SizedBox(
                      width: 220,
                      child: _SummaryTile(metric: metric, isArabic: isArabic),
                    ),
                  )
                  .toList(),
            ),
            if (priceInfo != null && priceInfo.isNotEmpty) ...[
              const SizedBox(height: 20),
              Text(
                isArabic ? 'مرجع التسعير' : 'Price Reference',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 16,
                runSpacing: 8,
                children: [
                  if (priceInfo['per_gram_main_karat'] != null)
                    Text(
                      isArabic
                          ? 'سعر العيار الرئيسي: ${_formatCurrency(_asDouble(priceInfo['per_gram_main_karat']))} لكل جرام'
                          : 'Main karat price: ${_formatCurrency(_asDouble(priceInfo['per_gram_main_karat']))} /g',
                    ),
                  if (priceInfo['per_gram_24k'] != null)
                    Text(
                      isArabic
                          ? 'سعر 24K: ${_formatCurrency(_asDouble(priceInfo['per_gram_24k']))} لكل جرام'
                          : '24K price: ${_formatCurrency(_asDouble(priceInfo['per_gram_24k']))} /g',
                    ),
                  if (priceInfo['gold_price_date'] != null)
                    Text(
                      isArabic
                          ? 'آخر تحديث: ${priceInfo['gold_price_date']}'
                          : 'Last update: ${priceInfo['gold_price_date']}',
                      style: const TextStyle(color: Colors.grey),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildChartCard(bool isArabic) {
    final items = _items;
    if (items.isEmpty) {
      return const SizedBox.shrink();
    }

    final sortedByValue = [...items]
      ..sort(
        (a, b) => _asDouble(
          b['market_value'],
        ).compareTo(_asDouble(a['market_value'])),
      );
    final topItems = sortedByValue.take(8).toList();
    final hasPositive = topItems.any(
      (item) => _asDouble(item['market_value']) > 0,
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
              isArabic ? 'أعلى الأصناف بالقيمة' : 'Top Items by Value',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            if (!hasPositive)
              _buildEmptyState(
                isArabic
                    ? 'لا توجد قيم سوقية موجبة لعرضها.'
                    : 'No positive market values to display.',
                Icons.show_chart,
              )
            else
              SizedBox(
                height: 280,
                child: _TopItemsValueChart(
                  items: topItems,
                  isArabic: isArabic,
                  formatCurrency: _formatCurrency,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTableCard(bool isArabic) {
    final items = _items;
    if (items.isEmpty) {
      return _buildEmptyState(
        isArabic
            ? 'لا توجد بيانات للمخزون الحالي.'
            : 'No inventory data available.',
        Icons.inventory,
      );
    }

    final dateFormat = DateFormat('yyyy-MM-dd');

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
              isArabic ? 'تفاصيل الأصناف' : 'Items Details',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                columns: [
                  DataColumn(label: Text(isArabic ? 'الصنف' : 'Item')),
                  DataColumn(label: Text(isArabic ? 'العيار' : 'Karat')),
                  DataColumn(label: Text(isArabic ? 'الكمية' : 'Quantity')),
                  DataColumn(
                    label: Text(
                      isArabic ? 'الوزن (عيار رئيسي)' : 'Weight (Main Karat)',
                    ),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'القيمة السوقية' : 'Market Value'),
                  ),
                  DataColumn(
                    label: Text(isArabic ? 'التقييم الدفتري' : 'Tag Value'),
                  ),
                  DataColumn(label: Text(isArabic ? 'الفرق' : 'Gap')),
                  DataColumn(label: Text(isArabic ? 'الحالة' : 'Status')),
                  DataColumn(
                    label: Text(
                      isArabic ? 'أيام منذ الحركة' : 'Days Since Move',
                    ),
                  ),
                  DataColumn(label: Text(isArabic ? 'مستندات' : 'Docs')),
                  DataColumn(
                    label: Text(isArabic ? 'آخر حركة' : 'Last Movement'),
                  ),
                ],
                rows: items.map((item) {
                  final itemCode = item['item_code'] ?? '';
                  final itemName = item['item_name'] ?? '';
                  final label = itemCode.isEmpty
                      ? itemName
                      : '$itemName ($itemCode)';
                  final lastMovement = item['last_movement_date'];
                  final formattedDate =
                      lastMovement == null || lastMovement == ''
                      ? '-'
                      : dateFormat.format(DateTime.parse(lastMovement));

                  return DataRow(
                    cells: [
                      DataCell(Text(label)),
                      DataCell(Text(item['karat']?.toString() ?? '-')),
                      DataCell(
                        Text(
                          _weightFormat.format(
                            _asDouble(item['effective_stock_quantity']),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(
                          _formatWeight(
                            _asDouble(item['effective_weight_main_karat']),
                          ),
                        ),
                      ),
                      DataCell(
                        Text(_formatCurrency(_asDouble(item['market_value']))),
                      ),
                      DataCell(
                        Text(_formatCurrency(_asDouble(item['tag_value']))),
                      ),
                      DataCell(
                        Text(_formatCurrency(_asDouble(item['valuation_gap']))),
                      ),
                      DataCell(_buildStatusChip(item, isArabic)),
                      DataCell(
                        Text(item['days_since_movement']?.toString() ?? '-'),
                      ),
                      DataCell(Text('${item['documents'] ?? 0}')),
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

  Widget _buildStatusChip(Map<String, dynamic> item, bool isArabic) {
    final status = item['status']?.toString() ?? 'active';
    Color background;
    IconData icon;
    String label;

    switch (status) {
      case 'negative_balance':
        background = Colors.red.shade100;
        icon = Icons.warning_amber;
        label = isArabic ? 'رصيد سالب' : 'Negative';
        break;
      case 'out_of_stock':
        background = Colors.grey.shade300;
        icon = Icons.do_not_disturb;
        label = isArabic ? 'غير متوفر' : 'Out of stock';
        break;
      case 'slow_moving':
        background = Colors.orange.shade100;
        icon = Icons.timer;
        label = isArabic ? 'حركة بطيئة' : 'Slow moving';
        break;
      default:
        background = Colors.green.shade100;
        icon = Icons.check_circle;
        label = isArabic ? 'نشط' : 'Active';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: Colors.black87),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(String message, IconData icon) {
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

class _TopItemsValueChart extends StatelessWidget {
  final List<Map<String, dynamic>> items;
  final bool isArabic;
  final String Function(num value) formatCurrency;

  const _TopItemsValueChart({
    required this.items,
    required this.isArabic,
    required this.formatCurrency,
  });

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final data = items.asMap().entries.map((entry) {
      final index = entry.key;
      final row = entry.value;
      final itemCode = row['item_code'] ?? '';
      final itemName = row['item_name'] ?? '';
      final label = itemCode.isEmpty ? itemName : '$itemName ($itemCode)';
      return _ChartItem(
        index: index,
        label: label,
        value: _asDouble(row['market_value']).clamp(0.0, double.infinity),
      );
    }).toList();

    final maxY = data.fold<double>(
      0,
      (prev, item) => math.max(prev, item.value),
    );
    final interval = maxY <= 0 ? 1.0 : maxY / 4;

    return BarChart(
      BarChartData(
        minY: 0,
        maxY: maxY <= 0 ? 1.0 : maxY * 1.1,
        alignment: BarChartAlignment.spaceAround,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: interval <= 0 ? 1.0 : interval,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: Colors.grey.withValues(alpha: 0.2), strokeWidth: 1),
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
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 80,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(right: 12),
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
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: SizedBox(
                    width: 120,
                    child: Transform.rotate(
                      angle: isArabic ? 0.6 : -0.6,
                      child: Text(
                        point.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barGroups: data
            .map(
              (item) => BarChartGroupData(
                x: item.index,
                barRods: [
                  BarChartRodData(
                    toY: item.value,
                    gradient: LinearGradient(
                      colors: [Colors.amber.shade600, Colors.orange.shade400],
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
              final label = isArabic ? 'القيمة السوقية' : 'Market Value';
              return BarTooltipItem(
                '${point.label}\n$label: ${formatCurrency(rod.toY)}',
                const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ChartItem {
  final int index;
  final String label;
  final double value;

  const _ChartItem({
    required this.index,
    required this.label,
    required this.value,
  });
}
