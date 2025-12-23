import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../providers/settings_provider.dart';

/// تقرير مستحقات المكافآت - يعرض المكافآت الموافق عليها ولم تُدفع بعد
class BonusPayablesReportScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const BonusPayablesReportScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<BonusPayablesReportScreen> createState() => _BonusPayablesReportScreenState();
}

class _BonusPayablesReportScreenState extends State<BonusPayablesReportScreen> {
  Map<String, dynamic>? _report;
  bool _isLoading = false;
  String? _error;

  String _currencySymbol = 'ر.س';
  int _currencyDecimals = 2;
  late NumberFormat _currencyFormat;

  @override
  void initState() {
    super.initState();
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
    final settings = Provider.of<SettingsProvider>(context, listen: false);
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
      final result = await widget.api.getBonusesPayablesReport();
      if (!mounted) return;
      setState(() => _report = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  String _formatCurrency(num value) => _currencyFormat.format(value);

  num _totalUnpaid() {
    final total = _report?['total_unpaid'];
    if (total is num) return total;
    return 0;
  }

  Map<String, dynamic> _statusSummary() {
    final raw = _report?['status_summary'];
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    return {};
  }

  List<Map<String, dynamic>> _employeesPayables() {
    final raw = _report?['employees_payables'];
    if (raw is List) {
      return raw
          .whereType<Map<String, dynamic>>()
          .map((item) => Map<String, dynamic>.from(item))
          .toList()
        ..sort(
          (a, b) => (b['total_amount'] as num? ?? 0)
              .compareTo(a['total_amount'] as num? ?? 0),
        );
    }
    return [];
  }

  Map<String, dynamic>? _accountInfo() {
    final raw = _report?['account_info'];
    if (raw is Map<String, dynamic>) {
      return raw;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = widget.isArabic;
    return Directionality(
      textDirection: isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isArabic ? 'تقرير مستحقات المكافآت' : 'Bonus Payables Report'),
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
      ),
    );
  }

  Widget _buildErrorState(bool isArabic) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 48, color: Colors.red.shade300),
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
          _buildSummaryCard(isArabic),
          const SizedBox(height: 16),
          _buildStatusCard(isArabic),
          const SizedBox(height: 16),
          _buildEmployeesCard(isArabic),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(bool isArabic) {
    final accountInfo = _accountInfo();
    final totalUnpaid = _totalUnpaid();
    final accountBalance = accountInfo?['balance'] as num?;
    final matches = accountInfo?['balance_matches'] as bool?;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.savings, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isArabic
                        ? 'إجمالي المكافآت الموافق عليها وغير المدفوعة'
                        : 'Total approved & unpaid bonuses',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              _formatCurrency(totalUnpaid),
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 16),
            if (accountInfo != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment:
                        isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                    children: [
                      Text(
                        isArabic
                            ? 'رصيد حساب مكافآت مستحقة (${accountInfo['account_number']})'
                            : 'Bonuses payable account (${accountInfo['account_number']})',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            matches == true ? Icons.verified : Icons.info_outline,
                            color: matches == false
                                ? Colors.orange
                                : Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              accountBalance != null
                                  ? _formatCurrency(accountBalance)
                                  : (isArabic ? 'غير متوفر' : 'Not available'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        matches == true
                            ? (isArabic
                                ? '✅ الرصيد مطابق لإجمالي المستحقات'
                                : '✅ Balance matches total payables')
                            : (isArabic
                                ? '⚠️ يوجد فرق يحتاج تحقق'
                                : '⚠️ Detected variance – please review'),
                        style: TextStyle(
                          color: matches == true ? Colors.green : Colors.orange,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (accountInfo == null)
              Text(
                isArabic
                    ? 'لم يتم العثور على حساب مكافآت مستحقة (215) في الدليل'
                    : 'Account 215 (Bonuses payable) was not found in chart of accounts',
                style: TextStyle(color: Colors.red.shade400),
              ),
            const SizedBox(height: 12),
            Text(
              isArabic
                  ? 'هذا التقرير يعتمد على المكافآت بالحالة "approved" ولم يتم دفعها بعد.'
                  : 'This report lists bonuses with status "approved" that are still unpaid.',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusCard(bool isArabic) {
    final summary = _statusSummary();
    if (summary.isEmpty) {
      return _buildEmptyState(
        icon: Icons.pie_chart_outline,
        message: isArabic ? 'لا توجد بيانات حالة متاحة' : 'No status data available',
      );
    }

    final chips = summary.entries.map((entry) {
      final count = entry.value is Map<String, dynamic>
          ? entry.value['count'] as num? ?? 0
          : 0;
      final total = entry.value is Map<String, dynamic>
          ? entry.value['total'] as num? ?? 0
          : 0;
      return _StatusChip(
        label: _localizedStatus(entry.key, isArabic),
        count: count.toInt(),
        totalFormatted: _formatCurrency(total),
      );
    }).toList();

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'توزيع حسب الحالة' : 'Status distribution',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: chips,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmployeesCard(bool isArabic) {
    final employees = _employeesPayables();
    if (employees.isEmpty) {
      return _buildEmptyState(
        icon: Icons.people_alt_outlined,
        message: isArabic
            ? 'لا توجد مكافآت مستحقة حالياً'
            : 'No pending bonus payables right now',
      );
    }

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: isArabic ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Text(
              isArabic ? 'تفاصيل حسب الموظف' : 'Per-employee details',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            ...employees.map((employee) {
              final total = employee['total_amount'] as num? ?? 0;
              final count = employee['bonuses_count'] as num? ?? 0;
              final code = employee['employee_code'] ?? '';
              final subtitle = isArabic
                  ? 'عدد المكافآت: $count | الكود: $code'
                  : 'Bonuses: $count | Code: $code';
              return Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                      child: Text(
                        _employeeInitial(employee['employee_name']),
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onPrimaryContainer,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    title: Text(
                      employee['employee_name']?.toString() ?? '-',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(subtitle),
                    trailing: Text(
                      _formatCurrency(total),
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  if (employee != employees.last)
                    const Divider(height: 8),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  String _employeeInitial(dynamic rawName) {
    final text = rawName?.toString().trim();
    if (text == null || text.isEmpty) {
      return '?';
    }
    final firstCodePoint = text.runes.isEmpty ? null : text.runes.first;
    if (firstCodePoint == null) {
      return '?';
    }
    return String.fromCharCode(firstCodePoint);
  }

  Widget _buildEmptyState({required IconData icon, required String message}) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Icon(icon, size: 48, color: Colors.grey.shade400),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  String _localizedStatus(String status, bool isArabic) {
    switch (status) {
      case 'pending':
        return isArabic ? 'بانتظار الموافقة' : 'Pending';
      case 'approved':
        return isArabic ? 'موافق عليه' : 'Approved';
      case 'paid':
        return isArabic ? 'مدفوع' : 'Paid';
      case 'rejected':
        return isArabic ? 'مرفوض' : 'Rejected';
      default:
        return status;
    }
  }
}

class _StatusChip extends StatelessWidget {
  final String label;
  final int count;
  final String totalFormatted;

  const _StatusChip({
    required this.label,
    required this.count,
    required this.totalFormatted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Theme.of(context).colorScheme.surfaceVariant,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('$count', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(totalFormatted, style: const TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}
