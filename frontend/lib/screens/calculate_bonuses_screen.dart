import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';

class CalculateBonusesScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const CalculateBonusesScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<CalculateBonusesScreen> createState() => _CalculateBonusesScreenState();
}

class _CalculateBonusesScreenState extends State<CalculateBonusesScreen> {
  DateTime _periodStart = DateTime.now().subtract(const Duration(days: 30));
  DateTime _periodEnd = DateTime.now();
  List<Map<String, dynamic>>? _previewResults;
  bool _loading = false;
  bool _saving = false;

  Future<void> _calculatePreview() async {
    setState(() {
      _loading = true;
      _previewResults = null;
    });

    try {
      final result = await widget.api.calculateBonuses(
        dateFrom: _periodStart.toIso8601String().split('T').first,
        dateTo: _periodEnd.toIso8601String().split('T').first,
      );

      final isSuccess = result['success'] == null || result['success'] == true;
      if (!isSuccess) {
        throw Exception(result['message'] ?? 'فشل احتساب المكافآت');
      }

      final bonusesRaw = result['bonuses'];
      List<dynamic> bonuses = [];
      if (bonusesRaw is List) {
        bonuses = bonusesRaw;
      } else if (bonusesRaw is Map) {
        bonuses = bonusesRaw.values.toList();
      }

      setState(() {
        _previewResults = bonuses.map((b) {
          // استخراج اسم الموظف من كائن employee
          String employeeName = 'غير محدد';
          if (b['employee'] is Map) {
            employeeName = b['employee']['name'] ?? 'غير محدد';
          } else if (b['employee_name'] != null) {
            employeeName = b['employee_name'];
          }

          // استخراج اسم القاعدة من كائن rule
          String ruleName = '';
          if (b['rule'] is Map) {
            ruleName = b['rule']['name'] ?? '';
          } else if (b['rule_name'] != null) {
            ruleName = b['rule_name'];
          }

          return {
            'employee_name': employeeName,
            'bonus_type': b['bonus_type'] ?? '',
            'amount': (b['amount'] as num?)?.toDouble() ?? 0.0,
            'rule_name': ruleName,
            'status': b['status'] ?? 'pending',
          };
        }).toList();
      });

      _showSnack(
        widget.isArabic
            ? 'تم احتساب ${_previewResults?.length ?? 0} مكافأة'
            : 'Calculated ${_previewResults?.length ?? 0} bonuses',
      );
    } catch (e) {
      _showSnack(e.toString(), isError: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _confirmAndSave() async {
    final isAr = widget.isArabic;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(isAr ? 'تأكيد الحفظ' : 'Confirm Save'),
        content: Text(
          isAr
              ? 'هل تريد حفظ ${_previewResults?.length ?? 0} مكافأة؟'
              : 'Save ${_previewResults?.length ?? 0} bonuses?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(isAr ? 'حفظ' : 'Save'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() => _saving = true);
      try {
        await widget.api.calculateBonuses(
          dateFrom: _periodStart.toIso8601String().split('T').first,
          dateTo: _periodEnd.toIso8601String().split('T').first,
        );
        _showSnack(isAr ? 'تم الحفظ بنجاح' : 'Saved successfully');
        if (mounted) Navigator.pop(context, true);
      } catch (e) {
        _showSnack(e.toString(), isError: true);
      } finally {
        if (mounted) setState(() => _saving = false);
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    final isAr = widget.isArabic;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Colors.red
            : Theme.of(context).colorScheme.primary,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: isAr ? 'إغلاق' : 'Close',
          textColor: Colors.white,
          onPressed: () {},
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final dateFormat = DateFormat('yyyy-MM-dd');

    return Scaffold(
      appBar: AppBar(
        title: Text(isAr ? 'احتساب المكافآت' : 'Calculate Bonuses'),
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isAr ? 'فترة الاحتساب' : 'Calculation Period',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _periodStart,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null) {
                                setState(() => _periodStart = picked);
                              }
                            },
                            child: InputDecorator(
                              decoration: InputDecoration(
                                labelText: isAr ? 'من تاريخ' : 'From Date',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.calendar_today),
                              ),
                              child: Text(dateFormat.format(_periodStart)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _periodEnd,
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2100),
                              );
                              if (picked != null) {
                                setState(() => _periodEnd = picked);
                              }
                            },
                            child: InputDecorator(
                              decoration: InputDecoration(
                                labelText: isAr ? 'إلى تاريخ' : 'To Date',
                                border: const OutlineInputBorder(),
                                prefixIcon: const Icon(Icons.calendar_today),
                              ),
                              child: Text(dateFormat.format(_periodEnd)),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _loading ? null : _calculatePreview,
                        icon: _loading
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : const Icon(Icons.calculate),
                        label: Text(
                          isAr ? 'معاينة النتائج' : 'Preview Results',
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            if (_previewResults != null) ...[
              Text(
                isAr
                    ? 'النتائج (${_previewResults!.length})'
                    : 'Results (${_previewResults!.length})',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: _previewResults!.isEmpty
                    ? Center(
                        child: Text(
                          isAr
                              ? 'لا توجد مكافآت للفترة المحددة'
                              : 'No bonuses for this period',
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.grey,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _previewResults!.length,
                        itemBuilder: (ctx, i) =>
                            _buildResultCard(_previewResults![i]),
                      ),
              ),
              const SizedBox(height: 16),
              if (_previewResults!.isNotEmpty)
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _saving ? null : _confirmAndSave,
                    icon: _saving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.save),
                    label: Text(isAr ? 'حفظ المكافآت' : 'Save Bonuses'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResultCard(Map<String, dynamic> result) {
    final status = result['status'] as String? ?? 'pending';
    final isAr = widget.isArabic;

    // تحديد لون ونص الحالة
    Color statusColor;
    String statusText;
    IconData statusIcon;

    switch (status) {
      case 'approved':
        statusColor = Colors.blue;
        statusText = isAr ? 'معتمدة' : 'Approved';
        statusIcon = Icons.check_circle;
        break;
      case 'paid':
        statusColor = Colors.green;
        statusText = isAr ? 'مدفوعة' : 'Paid';
        statusIcon = Icons.payment;
        break;
      case 'rejected':
        statusColor = Colors.red;
        statusText = isAr ? 'مرفوضة' : 'Rejected';
        statusIcon = Icons.cancel;
        break;
      default:
        statusColor = Colors.orange;
        statusText = isAr ? 'معلقة' : 'Pending';
        statusIcon = Icons.pending;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: const Color(0xFFFFD700).withValues(alpha: 0.2),
          child: const Icon(Icons.person, color: Color(0xFFFFD700)),
        ),
        title: Text(
          result['employee_name'] as String,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              result['rule_name'] as String? ?? result['bonus_type'] as String,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(statusIcon, size: 16, color: statusColor),
                const SizedBox(width: 4),
                Text(
                  statusText,
                  style: TextStyle(color: statusColor, fontSize: 12),
                ),
              ],
            ),
          ],
        ),
        trailing: Text(
          '${(result['amount'] as double).toStringAsFixed(2)} IQD',
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: Colors.green,
          ),
        ),
        isThreeLine: true,
      ),
    );
  }
}
