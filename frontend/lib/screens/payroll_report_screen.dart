import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/payroll_model.dart';

/// شاشة تقرير شهري شامل للرواتب
class PayrollReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  const PayrollReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<PayrollReportScreen> createState() => _PayrollReportScreenState();
}

class _PayrollReportScreenState extends State<PayrollReportScreen> {
  int _selectedYear = DateTime.now().year;
  int? _selectedMonth;
  List<PayrollModel> _entries = [];
  bool _loading = false;

  // إحصائيات محسوبة
  double _totalBasic = 0.0;
  double _totalAllowances = 0.0;
  double _totalDeductions = 0.0;
  double _totalNet = 0.0;
  int _paidCount = 0;
  int _pendingCount = 0;
  double _paidAmount = 0.0;
  double _pendingAmount = 0.0;

  @override
  void initState() {
    super.initState();
    _selectedMonth = DateTime.now().month;
    _loadReport();
  }

  Future<void> _loadReport() async {
    setState(() => _loading = true);
    try {
      final entries = await widget.api.getPayroll(
        year: _selectedYear,
        month: _selectedMonth,
      );
      setState(() {
        _entries = entries;
        _calculateStats();
      });
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  void _calculateStats() {
    _totalBasic = 0.0;
    _totalAllowances = 0.0;
    _totalDeductions = 0.0;
    _totalNet = 0.0;
    _paidCount = 0;
    _pendingCount = 0;
    _paidAmount = 0.0;
    _pendingAmount = 0.0;

    for (final entry in _entries) {
      _totalBasic += entry.basicSalary;
      _totalAllowances += entry.allowances;
      _totalDeductions += entry.deductions;
      _totalNet += entry.netSalary;

      if (entry.status == 'paid') {
        _paidCount++;
        _paidAmount += entry.netSalary;
      } else {
        _pendingCount++;
        _pendingAmount += entry.netSalary;
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.red
            : Theme.of(context).colorScheme.primary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    final years = List.generate(5, (index) => DateTime.now().year - 2 + index);
    final months = List.generate(12, (index) => index + 1);

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'تقرير الرواتب الشهري' : 'Monthly Payroll Report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadReport,
            tooltip: isAr ? 'تحديث' : 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          // ✅ فلاتر السنة والشهر
          Container(
            padding: const EdgeInsets.all(16),
            color: colorScheme.surface,
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    value: _selectedYear,
                    decoration: InputDecoration(
                      labelText: isAr ? 'السنة' : 'Year',
                      border: const OutlineInputBorder(),
                    ),
                    items: years
                        .map(
                          (year) => DropdownMenuItem(
                            value: year,
                            child: Text(year.toString()),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      setState(
                        () => _selectedYear = value ?? DateTime.now().year,
                      );
                      _loadReport();
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: DropdownButtonFormField<int?>(
                    value: _selectedMonth,
                    decoration: InputDecoration(
                      labelText: isAr ? 'الشهر' : 'Month',
                      border: const OutlineInputBorder(),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: null,
                        child: Text(isAr ? 'كل الأشهر' : 'All Months'),
                      ),
                      ...months.map(
                        (m) => DropdownMenuItem(value: m, child: Text('$m')),
                      ),
                    ],
                    onChanged: (value) {
                      setState(() => _selectedMonth = value);
                      _loadReport();
                    },
                  ),
                ),
              ],
            ),
          ),

          // ✅ بطاقات الإحصائيات
          if (!_loading)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  // الصف الأول: الإجمالي والمدفوع/المعلق
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          title: isAr ? 'الإجمالي' : 'Total',
                          value: _totalNet.toStringAsFixed(2),
                          icon: Icons.account_balance_wallet,
                          color: colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildStatCard(
                          title: isAr ? 'المدفوع' : 'Paid',
                          value: _paidAmount.toStringAsFixed(2),
                          subtitle: '$_paidCount ${isAr ? 'سجل' : 'records'}',
                          icon: Icons.check_circle,
                          color: Colors.green,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildStatCard(
                          title: isAr ? 'المعلق' : 'Pending',
                          value: _pendingAmount.toStringAsFixed(2),
                          subtitle:
                              '$_pendingCount ${isAr ? 'سجل' : 'records'}',
                          icon: Icons.pending,
                          color: Colors.orange,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // الصف الثاني: تفصيل المكونات
                  Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          title: isAr ? 'الأساسي' : 'Basic',
                          value: _totalBasic.toStringAsFixed(2),
                          icon: Icons.monetization_on,
                          color: Colors.blue,
                          compact: true,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatCard(
                          title: isAr ? 'البدلات' : 'Allowances',
                          value: _totalAllowances.toStringAsFixed(2),
                          icon: Icons.add_circle,
                          color: Colors.teal,
                          compact: true,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _buildStatCard(
                          title: isAr ? 'الخصومات' : 'Deductions',
                          value: _totalDeductions.toStringAsFixed(2),
                          icon: Icons.remove_circle,
                          color: Colors.red,
                          compact: true,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

          // ✅ قائمة السجلات التفصيلية
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _entries.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.receipt_long,
                          size: 64,
                          color: colorScheme.outline,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isAr ? 'لا توجد سجلات رواتب' : 'No payroll records',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: colorScheme.outline,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: _entries.length,
                    itemBuilder: (context, index) {
                      final entry = _entries[index];
                      final statusColor = _getStatusColor(entry.status);

                      return Card(
                        margin: const EdgeInsets.only(bottom: 12),
                        child: ExpansionTile(
                          leading: CircleAvatar(
                            backgroundColor: statusColor.withValues(alpha: 0.1),
                            child: Icon(Icons.person, color: statusColor),
                          ),
                          title: Text(
                            entry.employee?.name ?? '#${entry.employeeId}',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          subtitle: Text(
                            '${isAr ? 'الصافي' : 'Net'}: ${entry.netSalary.toStringAsFixed(2)} | ${entry.status}',
                          ),
                          children: [
                            Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                children: [
                                  _buildDetailRow(
                                    isAr ? 'الراتب الأساسي' : 'Basic Salary',
                                    entry.basicSalary.toStringAsFixed(2),
                                  ),
                                  _buildDetailRow(
                                    isAr ? 'البدلات' : 'Allowances',
                                    entry.allowances.toStringAsFixed(2),
                                    color: Colors.green,
                                  ),
                                  _buildDetailRow(
                                    isAr ? 'الخصومات' : 'Deductions',
                                    entry.deductions.toStringAsFixed(2),
                                    color: Colors.red,
                                  ),
                                  const Divider(),
                                  _buildDetailRow(
                                    isAr ? 'الصافي' : 'Net Salary',
                                    entry.netSalary.toStringAsFixed(2),
                                    isBold: true,
                                  ),
                                  if (entry.paidDate != null)
                                    _buildDetailRow(
                                      isAr ? 'تاريخ الدفع' : 'Paid Date',
                                      '${entry.paidDate!.year}-${entry.paidDate!.month.toString().padLeft(2, '0')}-${entry.paidDate!.day.toString().padLeft(2, '0')}',
                                    ),
                                  if (entry.voucher != null)
                                    _buildDetailRow(
                                      isAr ? 'رقم السند' : 'Voucher #',
                                      entry.voucher!.voucherNumber,
                                    ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required String title,
    required String value,
    String? subtitle,
    required IconData icon,
    required Color color,
    bool compact = false,
  }) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: EdgeInsets.all(compact ? 12 : 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: compact ? 20 : 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            SizedBox(height: compact ? 4 : 8),
            Text(
              value,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                fontSize: compact ? 18 : 24,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(
    String label,
    String value, {
    Color? color,
    bool isBold = false,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: color,
              fontWeight: isBold ? FontWeight.bold : null,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isBold ? FontWeight.bold : FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'paid':
        return Colors.green;
      case 'approved':
        return Colors.blue;
      case 'cancelled':
        return Colors.red;
      default:
        return Colors.orange;
    }
  }
}
