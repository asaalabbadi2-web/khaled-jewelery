import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';
import '../theme/app_theme.dart' as theme;

class VoucherDetailsScreen extends StatefulWidget {
  final int voucherId;

  const VoucherDetailsScreen({Key? key, required this.voucherId})
    : super(key: key);

  @override
  State<VoucherDetailsScreen> createState() => _VoucherDetailsScreenState();
}

class _VoucherDetailsScreenState extends State<VoucherDetailsScreen> {
  final ApiService _apiService = ApiService();

  Map<String, dynamic>? _voucher;
  bool _isLoading = true;
  String? _error;

  final NumberFormat _currencyFormat = NumberFormat('#,##0.00', 'ar');
  final NumberFormat _weightFormat = NumberFormat('#,##0.000', 'ar');

  @override
  void initState() {
    super.initState();
    _loadVoucher();
  }

  Future<void> _loadVoucher() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final voucher = await _apiService.getVoucher(widget.voucherId);
      setState(() {
        _voucher = voucher;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _deleteVoucher() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد الحذف'),
        content: const Text(
          'هل أنت متأكد من حذف هذا السند؟\nلا يمكن التراجع عن هذا الإجراء.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: theme.AppColors.error,
            ),
            child: const Text('حذف'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await _apiService.deleteVoucher(widget.voucherId);
        if (!mounted) return;
        _showSnack('تم حذف السند بنجاح');
        Navigator.pop(context, true);
      } catch (e) {
        if (!mounted) return;
        _showSnack('خطأ في الحذف: $e', error: true);
      }
    }
  }

  Future<void> _cancelVoucher() async {
    String? reason;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إلغاء السند'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('الرجاء إدخال سبب الإلغاء:'),
            const SizedBox(height: 16),
            TextField(
              decoration: const InputDecoration(
                hintText: 'سبب الإلغاء',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              onChanged: (value) => reason = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: theme.AppColors.error,
            ),
            child: const Text('إلغاء السند'),
          ),
        ],
      ),
    );

    if (confirm == true && reason != null && reason!.isNotEmpty) {
      try {
        await _apiService.cancelVoucher(widget.voucherId, reason!);
        if (!mounted) return;
        _showSnack('تم إلغاء السند بنجاح');
        _loadVoucher();
      } catch (e) {
        if (!mounted) return;
        _showSnack('خطأ في الإلغاء: $e', error: true);
      }
    } else if (confirm == true) {
      _showSnack('يجب إدخال سبب الإلغاء', error: true);
    }
  }

  Future<void> _approveVoucher() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('اعتماد السند'),
        content: const Text(
          'هل تريد اعتماد (ترحيل) هذا السند الآن؟ سيتم إنشاء قيد محاسبي.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(
              foregroundColor: theme.AppColors.primaryGold,
            ),
            child: const Text('اعتماد'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await _apiService.approveVoucher(widget.voucherId);
      if (!mounted) return;
      _showSnack('تم اعتماد السند');
      _loadVoucher();
    } catch (e) {
      if (!mounted) return;
      _showSnack('خطأ في اعتماد السند: $e', error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('تفاصيل السند')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null || _voucher == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('تفاصيل السند')),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline, size: 64, color: Colors.red[300]),
              const SizedBox(height: 16),
              Text('خطأ: $_error'),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: _loadVoucher,
                child: const Text('إعادة المحاولة'),
              ),
            ],
          ),
        ),
      );
    }

    final voucher = _voucher!;
    final voucherType = voucher['voucher_type'] ?? 'unknown';
    final status = voucher['status'] ?? 'active';
    final isCancelled = status == 'cancelled';
    final isActive = status == 'active';
  final double? amountCash = _toDouble(voucher['amount_cash']);
  final double? amountGold = _toDouble(voucher['amount_gold']);

    Color typeColor;
    IconData typeIcon;
    String typeText;

    switch (voucherType) {
      case 'receipt':
        typeColor = Colors.green;
        typeIcon = Icons.south;
        typeText = 'سند قبض';
        break;
      case 'payment':
        typeColor = Colors.red;
        typeIcon = Icons.north;
        typeText = 'سند صرف';
        break;
      case 'adjustment':
        typeColor = Colors.orange;
        typeIcon = Icons.balance;
        typeText = 'سند تسوية';
        break;
      default:
        typeColor = Colors.grey;
        typeIcon = Icons.help;
        typeText = 'غير محدد';
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(typeText),
        backgroundColor: typeColor,
        actions: [
          if (isActive) ...[
            IconButton(
              icon: const Icon(Icons.cancel),
              onPressed: _cancelVoucher,
              tooltip: 'إلغاء السند',
            ),
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteVoucher,
              tooltip: 'حذف السند',
            ),
          ],
          // Approve action for pending vouchers
          if (!isCancelled && (voucher['status'] ?? '') != 'approved')
            IconButton(
              icon: const Icon(Icons.check_circle_outline),
              onPressed: () async => await _approveVoucher(),
              tooltip: 'اعتماد/ترحيل السند',
            ),
          IconButton(
            icon: const Icon(Icons.print),
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('الطباعة قريباً...')),
              );
            },
            tooltip: 'طباعة',
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _loadVoucher,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header Card
              Card(
                elevation: 4,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: typeColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(typeIcon, color: typeColor, size: 32),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  voucher['voucher_number'] ?? '',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.bold,
                                    decoration: isCancelled
                                        ? TextDecoration.lineThrough
                                        : null,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 4,
                                  ),
                                  decoration: BoxDecoration(
                                    color: typeColor.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  child: Text(
                                    typeText,
                                    style: TextStyle(
                                      color: typeColor,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 24),
                      _buildInfoRow(
                        'التاريخ',
                        voucher['date'] ?? '',
                        Icons.calendar_today,
                      ),
                      if (isCancelled) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.red.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.red, width: 1),
                          ),
                          child: Row(
                            children: [
                              const Icon(Icons.cancel, color: Colors.red),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'السند ملغى',
                                      style: TextStyle(
                                        color: Colors.red,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    if (voucher['cancellation_reason'] != null)
                                      Text(
                                        'السبب: ${voucher['cancellation_reason']}',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Amount Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'المبلغ',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const Divider(),
                      if (amountCash != null && amountCash > 0)
                        _buildAmountRow(
                          'المبلغ النقدي',
                          '${_currencyFormat.format(amountCash)} ر.س',
                          Icons.money,
                          Colors.green,
                        ),
                      if (amountGold != null && amountGold > 0)
                        _buildAmountRow(
                          'المبلغ الذهبي',
                          '${_weightFormat.format(amountGold)} غرام (${voucher['gold_karat'] ?? 21} قيراط)',
                          Icons.opacity,
                          Colors.amber,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Party Card
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'الطرف',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const Divider(),
                      _buildInfoRow(
                        'نوع الطرف',
                        _getPartyTypeName(voucher['party_type']),
                        Icons.category,
                      ),
                      if (voucher['customer'] != null)
                        _buildInfoRow(
                          'العميل',
                          voucher['customer']['name'],
                          Icons.person,
                        ),
                      if (voucher['supplier'] != null)
                        _buildInfoRow(
                          'المورد',
                          voucher['supplier']['name'],
                          Icons.store,
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Description Card
              if (voucher['description'] != null &&
                  voucher['description'].toString().isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'البيان',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const Divider(),
                        Text(
                          voucher['description'],
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // Reference Card
              if (voucher['reference_type'] != null &&
                  voucher['reference_type'] != 'manual')
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'المرجع',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const Divider(),
                        _buildInfoRow(
                          'نوع المرجع',
                          _getReferenceTypeName(voucher['reference_type']),
                          Icons.link,
                        ),
                        if (voucher['reference_id'] != null)
                          _buildInfoRow(
                            'رقم المرجع',
                            voucher['reference_id'].toString(),
                            Icons.tag,
                          ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // Notes Card
              if (voucher['notes'] != null &&
                  voucher['notes'].toString().isNotEmpty)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'ملاحظات',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.black87,
                          ),
                        ),
                        const Divider(),
                        Text(
                          voucher['notes'],
                          style: const TextStyle(
                            fontSize: 14,
                            color: Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),

              // Metadata Card
              Card(
                color: Colors.grey[100],
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'معلومات إضافية',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const Divider(),
                      _buildInfoRow(
                        'تاريخ الإنشاء',
                        _formatDateTime(voucher['created_at']),
                        Icons.access_time,
                      ),
                      if (voucher['updated_at'] != null)
                        _buildInfoRow(
                          'آخر تحديث',
                          _formatDateTime(voucher['updated_at']),
                          Icons.update,
                        ),
                      if (voucher['created_by'] != null)
                        _buildInfoRow(
                          'المستخدم',
                          voucher['created_by'],
                          Icons.person,
                        ),
                    ],
                  ),
                ),
              ),

              // سجل التعديلات (تجريبي)
              if (voucher['audit_log'] != null &&
                  voucher['audit_log'] is List &&
                  voucher['audit_log'].isNotEmpty)
                Card(
                  color: const Color(0xFFFFF8E1),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(Icons.history, color: Color(0xFFFFD700)),
                            SizedBox(width: 8),
                            Text(
                              'سجل التعديلات',
                              style: TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        const Divider(),
                        ...voucher['audit_log']
                            .map<Widget>(
                              (entry) => Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 4,
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.person,
                                      size: 18,
                                      color: Colors.grey[700],
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      entry['user'] ?? '---',
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.update,
                                      size: 16,
                                      color: Colors.grey[600],
                                    ),
                                    const SizedBox(width: 2),
                                    Text(_formatDateTime(entry['timestamp'])),
                                    const SizedBox(width: 8),
                                    if (entry['action'] != null)
                                      Text(
                                        '(${entry['action']})',
                                        style: const TextStyle(
                                          fontSize: 12,
                                          color: Colors.black54,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            )
                            .toList(),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  void _showSnack(String message, {bool error = false}) {
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor:
            error ? theme.AppColors.error : theme.AppColors.primaryGold,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }

  Widget _buildInfoRow(String label, String value, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountRow(
    String label,
    String value,
    IconData icon,
    Color color,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 24, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getPartyTypeName(String? type) {
    switch (type) {
      case 'customer':
        return 'عميل';
      case 'supplier':
        return 'مورد';
      case 'other':
        return 'آخر';
      default:
        return 'غير محدد';
    }
  }

  String _getReferenceTypeName(String? type) {
    switch (type) {
      case 'invoice':
        return 'فاتورة';
      case 'journal_entry':
        return 'قيد محاسبي';
      case 'manual':
        return 'يدوي';
      default:
        return 'غير محدد';
    }
  }

  String _formatDateTime(String? dateTime) {
    if (dateTime == null) return 'غير محدد';
    try {
      final dt = DateTime.parse(dateTime);
      return DateFormat('yyyy-MM-dd HH:mm').format(dt);
    } catch (e) {
      return dateTime;
    }
  }
}
