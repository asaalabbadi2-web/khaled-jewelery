import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../api_service.dart';

class DualSystemReconciliationScreen extends StatefulWidget {
  const DualSystemReconciliationScreen({Key? key}) : super(key: key);

  @override
  State<DualSystemReconciliationScreen> createState() =>
      _DualSystemReconciliationScreenState();
}

class _DualSystemReconciliationScreenState
    extends State<DualSystemReconciliationScreen> {
  final ApiService _apiService = ApiService();
  Map<String, dynamic>? _reportData;
  bool _isLoading = false;
  DateTime _selectedDate = DateTime.now();
  double _threshold = 100.0;

  double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }

  @override
  void initState() {
    super.initState();
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() => _isLoading = true);
    try {
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      final response = await _apiService.getJson(
        '/reports/dual-system-reconciliation',
        queryParameters: {
          'date': dateStr,
          'threshold': _threshold.toString(),
        },
      );
      if (!mounted) return;
      setState(() {
        _reportData = response;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('خطأ في تحميل التقرير: $e')),
      );
    }
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'balanced':
        return Colors.green;
      case 'unbalanced':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }

  Color _getSeverityColor(String severity) {
    switch (severity) {
      case 'error':
        return Colors.red;
      case 'warning':
        return Colors.orange;
      default:
        return Colors.blue;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تقرير المطابقة المزدوجة',
            style: TextStyle(fontFamily: 'Cairo')),
        backgroundColor: const Color(0xFFD4AF37),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadReport,
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettings,
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _reportData == null
              ? const Center(child: Text('لا توجد بيانات'))
              : _buildReportContent(),
    );
  }

  Widget _buildReportContent() {
  final status = (_reportData!['status'] as String?) ?? 'balanced';
  final cashSystem = (_reportData!['cash_system'] as Map<String, dynamic>?) ?? {};
  final weightSystem = (_reportData!['weight_system'] as Map<String, dynamic>?) ?? {};
  final reconciliation = (_reportData!['reconciliation'] as Map<String, dynamic>?) ?? {};
  final alerts = (_reportData!['alerts'] as List<dynamic>?) ?? const [];
  final goldPrice = (_reportData!['gold_price'] as Map<String, dynamic>?) ?? {};

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status Card
          _buildStatusCard(status),
          const SizedBox(height: 16),

          // Gold Price Card
          _buildGoldPriceCard(goldPrice),
          const SizedBox(height: 16),

          // Cash System Card
          _buildCashSystemCard(cashSystem),
          const SizedBox(height: 16),

          // Weight System Card
          _buildWeightSystemCard(weightSystem),
          const SizedBox(height: 16),

          // Reconciliation Card
          _buildReconciliationCard(reconciliation),
          const SizedBox(height: 16),

          // Alerts
          if (alerts.isNotEmpty) ...[
            _buildAlertsSection(alerts),
            const SizedBox(height: 16),
          ],

          // Recommendations
          _buildRecommendationsSection(),
        ],
      ),
    );
  }

  Widget _buildStatusCard(String status) {
    final isBalanced = status == 'balanced';
    return Card(
      elevation: 4,
      color: _getStatusColor(status).withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            Icon(
              isBalanced ? Icons.check_circle : Icons.warning,
              color: _getStatusColor(status),
              size: 48,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'حالة النظام',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo',
                      color: Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    isBalanced ? 'متوازن ✅' : 'غير متوازن ⚠️',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Cairo',
                      color: _getStatusColor(status),
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

  Widget _buildGoldPriceCard(Map<String, dynamic> goldPrice) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '💰 سعر الذهب الحالي',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
              ),
            ),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildPriceItem(
                  'عيار 24',
                  _asDouble(goldPrice['24k']).toStringAsFixed(2),
                ),
                _buildPriceItem(
                  'العيار الرئيسي',
                  _asDouble(goldPrice['main_karat']).toStringAsFixed(2),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPriceItem(String label, String value) {
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontFamily: 'Cairo',
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$value ر.س/جم',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            fontFamily: 'Cairo',
            color: Color(0xFFD4AF37),
          ),
        ),
      ],
    );
  }

  Widget _buildCashSystemCard(Map<String, dynamic> cashSystem) {
  final totalValue = _asDouble(cashSystem['total_inventory_value']);
  final avgCost = _asDouble(cashSystem['avg_cost_per_gram']);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '💵 النظام النقدي (Cash)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
              ),
            ),
            const Divider(),
            _buildInfoRow('إجمالي قيمة المخزون', '${totalValue.toStringAsFixed(2)} ر.س'),
            _buildInfoRow('متوسط التكلفة', '${avgCost.toStringAsFixed(2)} ر.س/جم'),
          ],
        ),
      ),
    );
  }

  Widget _buildWeightSystemCard(Map<String, dynamic> weightSystem) {
  final totalGrams = _asDouble(weightSystem['total_inventory_grams']);
  final currentValue = _asDouble(weightSystem['current_value']);

    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '⚖️ النظام الوزني (Weight)',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
              ),
            ),
            const Divider(),
            _buildInfoRow('إجمالي الوزن', '${totalGrams.toStringAsFixed(3)} جرام'),
            _buildInfoRow('القيمة الحالية', '${currentValue.toStringAsFixed(2)} ر.س'),
          ],
        ),
      ),
    );
  }

  Widget _buildReconciliationCard(Map<String, dynamic> reconciliation) {
  final unrealizedGain = _asDouble(reconciliation['unrealized_gain_loss']);
  final variance = _asDouble(reconciliation['value_variance']);
  final variancePct = _asDouble(reconciliation['value_variance_pct']);
  final weightCheck =
    (reconciliation['weight_balance_check'] as Map<String, dynamic>?) ?? {};
  final isBalanced = (weightCheck['is_balanced'] as bool?) ?? false;

    return Card(
      elevation: 2,
      color: isBalanced ? Colors.green.shade50 : Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '🔄 التسوية والمقارنة',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
              ),
            ),
            const Divider(),
            _buildInfoRow(
              'الربح/الخسارة غير المحققة',
              '${unrealizedGain.toStringAsFixed(2)} ر.س',
              color: unrealizedGain >= 0 ? Colors.green : Colors.red,
            ),
            _buildInfoRow(
              'فرق القيمة',
              '${variance.toStringAsFixed(2)} ر.س (${variancePct.toStringAsFixed(2)}%)',
            ),
            _buildInfoRow(
              'توازن القيود الوزنية',
              isBalanced ? 'متوازن ✅' : 'غير متوازن ❌',
              color: isBalanced ? Colors.green : Colors.red,
            ),
            if (!isBalanced) ...[
              const SizedBox(height: 8),
              Text(
                'عدم التوازن: ${weightCheck['imbalance']} جرام',
                style: const TextStyle(
                  color: Colors.red,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'Cairo',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAlertsSection(List<dynamic> alerts) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '⚠️ التنبيهات',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
                color: Colors.red,
              ),
            ),
            const Divider(),
            ...alerts.map((alert) => _buildAlertItem(alert as Map<String, dynamic>)),
          ],
        ),
      ),
    );
  }

  Widget _buildAlertItem(Map<String, dynamic> alert) {
    final severity = alert['severity'] as String;
    final message = alert['message'] as String;
    final recommendation = alert['recommendation'] as String?;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: _getSeverityColor(severity).withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _getSeverityColor(severity)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_getSeverityIcon(severity),
                  color: _getSeverityColor(severity), size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontFamily: 'Cairo',
                    fontWeight: FontWeight.bold,
                    color: _getSeverityColor(severity),
                  ),
                ),
              ),
            ],
          ),
          if (recommendation != null) ...[
            const SizedBox(height: 8),
            Text(
              '💡 $recommendation',
              style: const TextStyle(
                fontFamily: 'Cairo',
                fontSize: 13,
                color: Colors.grey,
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getSeverityIcon(String severity) {
    switch (severity) {
      case 'error':
        return Icons.error;
      case 'warning':
        return Icons.warning;
      default:
        return Icons.info;
    }
  }

  Widget _buildRecommendationsSection() {
    final recommendations = _reportData!['recommendations'] as List<dynamic>?;
    if (recommendations == null || recommendations.isEmpty) return const SizedBox.shrink();

    return Card(
      elevation: 2,
      color: Colors.blue.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '💡 التوصيات',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                fontFamily: 'Cairo',
                color: Colors.blue,
              ),
            ),
            const Divider(),
            ...recommendations.map((rec) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('• ', style: TextStyle(fontSize: 16)),
                      Expanded(
                        child: Text(
                          rec as String,
                          style: const TextStyle(
                            fontFamily: 'Cairo',
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Cairo',
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontFamily: 'Cairo',
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color ?? Colors.black,
            ),
          ),
        ],
      ),
    );
  }

  void _showSettings() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إعدادات التقرير', style: TextStyle(fontFamily: 'Cairo')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: const Text('التاريخ', style: TextStyle(fontFamily: 'Cairo')),
              subtitle: Text(
                DateFormat('yyyy-MM-dd').format(_selectedDate),
                style: const TextStyle(fontFamily: 'Cairo'),
              ),
              trailing: const Icon(Icons.calendar_today),
              onTap: () async {
                final date = await showDatePicker(
                  context: context,
                  initialDate: _selectedDate,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (date != null) {
                  setState(() => _selectedDate = date);
                }
              },
            ),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                labelText: 'حد التحذير (ر.س)',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
              controller: TextEditingController(text: _threshold.toString()),
              onChanged: (value) {
                _threshold = double.tryParse(value) ?? 100.0;
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء', style: TextStyle(fontFamily: 'Cairo')),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _loadReport();
            },
            child: const Text('تطبيق', style: TextStyle(fontFamily: 'Cairo')),
          ),
        ],
      ),
    );
  }
}
