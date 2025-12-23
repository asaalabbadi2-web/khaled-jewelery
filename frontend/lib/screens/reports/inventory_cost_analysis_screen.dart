import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../api_service.dart';

class InventoryCostAnalysisScreen extends StatefulWidget {
  const InventoryCostAnalysisScreen({Key? key}) : super(key: key);

  @override
  State<InventoryCostAnalysisScreen> createState() =>
      _InventoryCostAnalysisScreenState();
}

class _InventoryCostAnalysisScreenState
    extends State<InventoryCostAnalysisScreen> {
  final ApiService _apiService = ApiService();
  bool _loading = false;
  Map<String, dynamic>? _data;
  DateTime _startDate = DateTime(DateTime.now().year, 1, 1);
  DateTime _endDate = DateTime.now();

  @override
  void initState() {
    super.initState();
    _load();
  }

  double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _startDate : _endDate,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _startDate = picked;
        } else {
          _endDate = picked;
        }
      });
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final response = await _apiService.getJson(
        '/reports/inventory-cost-analysis',
        queryParameters: {
          'start_date': DateFormat('yyyy-MM-dd').format(_startDate),
          'end_date': DateFormat('yyyy-MM-dd').format(_endDate),
        },
      );
      if (!mounted) return;
      setState(() {
        _data = response;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('تعذر تحميل التقرير: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تحليل تكلفة المخزون',
            style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: const Color(0xFFD4AF37),
        actions: [
          IconButton(onPressed: _load, icon: const Icon(Icons.refresh)),
          IconButton(onPressed: () => _pickDate(isStart: true), icon: const Icon(Icons.date_range)),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _data == null
              ? const Center(child: Text('لا توجد بيانات'))
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    final current = (_data!['current_inventory'] as Map<String, dynamic>? ) ?? {};
    final purchases = (_data!['purchases_analysis'] as Map<String, dynamic>?) ?? {};
    final comparison = (_data!['comparison'] as Map<String, dynamic>?) ?? {};
    final summary = (_data!['executive_summary'] as Map<String, dynamic>?) ?? {};
    final period = (_data!['period'] as Map<String, dynamic>?) ?? {};

    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPeriodCard(period),
          const SizedBox(height: 12),
          _buildSummaryCard(summary),
          const SizedBox(height: 12),
          _buildCurrentInventoryCard(current),
          const SizedBox(height: 12),
          _buildPurchasesCard(purchases),
          const SizedBox(height: 12),
          _buildComparisonCard(comparison),
          const SizedBox(height: 12),
          _buildMonthlyBreakdown(purchases['monthly_breakdown'] as List<dynamic>?),
        ],
      ),
    );
  }

  Widget _buildPeriodCard(Map<String, dynamic> period) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('الفترة',
                    style: TextStyle(
                        fontFamily: 'Cairo',
                        fontSize: 16,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${period['start_date'] ?? '-'} → ${period['end_date'] ?? '-'}',
                    style: const TextStyle(fontFamily: 'Cairo')),
                Text('الأيام: ${period['days'] ?? '-'}',
                    style: const TextStyle(fontFamily: 'Cairo', color: Colors.grey)),
              ],
            ),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFD4AF37)),
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('تحديث', style: TextStyle(fontFamily: 'Cairo')),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(Map<String, dynamic> summary) {
    final status = (summary['inventory_status'] as String?) ?? 'unknown';
    final priceTrend = (summary['price_trend'] as String?) ?? 'stable';
    final keyMetric = (summary['key_metric'] as String?) ?? '';
    final action = (summary['action_item'] as String?) ?? '';

    Color trendColor;
    switch (priceTrend) {
      case 'increasing':
        trendColor = Colors.green;
        break;
      case 'decreasing':
        trendColor = Colors.red;
        break;
      default:
        trendColor = Colors.blueGrey;
    }

    return Card(
      elevation: 3,
      color: Colors.blueGrey.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  status == 'healthy' ? Icons.check_circle : Icons.info,
                  color: Colors.green,
                ),
                const SizedBox(width: 8),
                Text('الملخص التنفيذي',
                    style: TextStyle(
                      fontFamily: 'Cairo',
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade700,
                    )),
              ],
            ),
            const SizedBox(height: 8),
            Text(keyMetric,
                style: const TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text('اتجاه الأسعار: $priceTrend',
                style: TextStyle(fontFamily: 'Cairo', color: trendColor)),
            const SizedBox(height: 4),
            Text('التوصية: $action',
                style: const TextStyle(fontFamily: 'Cairo', color: Colors.black87)),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentInventoryCard(Map<String, dynamic> current) {
    final totalValue = _asDouble(current['total_value']);
    final totalWeight = _asDouble(current['total_weight_grams']);
    final avgCost = _asDouble(current['avg_cost_per_gram']);
    final marketValue = _asDouble(current['market_value']);
    final unrealized = _asDouble(current['unrealized_gain_loss']);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('المخزون الحالي',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const Divider(),
            _infoRow('القيمة الدفترية', '${totalValue.toStringAsFixed(2)} ر.س'),
            _infoRow('الوزن', '${totalWeight.toStringAsFixed(3)} جم'),
            _infoRow('متوسط التكلفة', '${avgCost.toStringAsFixed(2)} ر.س/جم'),
            _infoRow('القيمة السوقية', '${marketValue.toStringAsFixed(2)} ر.س'),
            _infoRow(
              'ربح/خسارة غير محققة',
              '${unrealized.toStringAsFixed(2)} ر.س',
              valueColor: unrealized >= 0 ? Colors.green : Colors.red,
            ),
            const SizedBox(height: 6),
            if (current['details'] is List<dynamic>)
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: (current['details'] as List)
                    .map((d) => Chip(
                          label: Text(
                            '${d['account_name']} (${d['value']})',
                            style: const TextStyle(fontFamily: 'Cairo'),
                          ),
                        ))
                    .toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPurchasesCard(Map<String, dynamic> purchases) {
    final totalValue = _asDouble(purchases['total_purchases_value']);
    final totalWeight = _asDouble(purchases['total_purchases_weight']);
    final avg = _asDouble(purchases['avg_purchase_cost']);
    final min = _asDouble(purchases['min_purchase_price']);
    final max = _asDouble(purchases['max_purchase_price']);
    final trend = (purchases['price_trend'] as String?) ?? 'stable';
    final trendPct = _asDouble(purchases['trend_percentage']);

    Color trendColor;
    switch (trend) {
      case 'increasing':
        trendColor = Colors.green;
        break;
      case 'decreasing':
        trendColor = Colors.red;
        break;
      default:
        trendColor = Colors.blueGrey;
    }

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('المشتريات خلال الفترة',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const Divider(),
            _infoRow('القيمة الإجمالية', '${totalValue.toStringAsFixed(2)} ر.س'),
            _infoRow('الوزن الإجمالي', '${totalWeight.toStringAsFixed(3)} جم'),
            _infoRow('متوسط تكلفة الشراء', '${avg.toStringAsFixed(2)} ر.س/جم'),
            _infoRow('أقل سعر شراء', '${min.toStringAsFixed(2)} ر.س/جم'),
            _infoRow('أعلى سعر شراء', '${max.toStringAsFixed(2)} ر.س/جم'),
            _infoRow(
              'اتجاه الأسعار',
              '$trend (${trendPct.toStringAsFixed(2)}%)',
              valueColor: trendColor,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildComparisonCard(Map<String, dynamic> comparison) {
    final diff = _asDouble(comparison['cost_difference']);
    final diffPct = _asDouble(comparison['difference_percentage']);
    final interpretation = (comparison['interpretation'] as String?) ?? '';
    final recommendation = (comparison['recommendation'] as String?) ?? '';
    final market = (comparison['market_comparison'] as String?) ?? '';
    final marketPrice = _asDouble(comparison['current_market_price']);

    return Card(
      elevation: 2,
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('المقارنة والتحليل',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const Divider(),
            _infoRow('فرق التكلفة', '${diff.toStringAsFixed(2)} ر.س'),
            _infoRow('نسبة الفرق', '${diffPct.toStringAsFixed(2)}%'),
            _infoRow('السعر الحالي', '${marketPrice.toStringAsFixed(2)} ر.س/جم'),
            const SizedBox(height: 6),
            Text(interpretation,
                style: const TextStyle(fontFamily: 'Cairo', color: Colors.black87)),
            if (recommendation.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('التوصية: $recommendation',
                  style: const TextStyle(fontFamily: 'Cairo', color: Colors.blueGrey)),
            ],
            if (market.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('مقارنة السوق: $market',
                  style: const TextStyle(fontFamily: 'Cairo', color: Colors.green)),
            ]
          ],
        ),
      ),
    );
  }

  Widget _buildMonthlyBreakdown(List<dynamic>? months) {
    if (months == null || months.isEmpty) {
      return const SizedBox.shrink();
    }
    return Card(
      elevation: 1,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('تحليل شهري',
                style: TextStyle(
                    fontFamily: 'Cairo',
                    fontSize: 16,
                    fontWeight: FontWeight.bold)),
            const Divider(),
            ...months.map((m) {
              final month = m['month'] as String? ?? '-';
              final value = _asDouble(m['total_value']);
              final weight = _asDouble(m['total_weight']);
              final avg = _asDouble(m['avg_cost']);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(month, style: const TextStyle(fontFamily: 'Cairo')),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('${value.toStringAsFixed(0)} ر.س',
                            style: const TextStyle(fontFamily: 'Cairo')),
                        Text('${weight.toStringAsFixed(2)} جم | ${avg.toStringAsFixed(2)} ر.س/جم',
                            style: const TextStyle(fontFamily: 'Cairo', color: Colors.grey)),
                      ],
                    )
                  ],
                ),
              );
            })
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  fontFamily: 'Cairo', fontSize: 14, color: Colors.grey)),
          Text(value,
              style: TextStyle(
                  fontFamily: 'Cairo',
                  fontSize: 15,
                  fontWeight: FontWeight.bold,
                  color: valueColor ?? Colors.black)),
        ],
      ),
    );
  }
}
