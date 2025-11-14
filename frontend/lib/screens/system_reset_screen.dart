import 'package:flutter/material.dart';
import '../api_service.dart';

class SystemResetScreen extends StatefulWidget {
  @override
  _SystemResetScreenState createState() => _SystemResetScreenState();
}

class _SystemResetScreenState extends State<SystemResetScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = false;
  Map<String, dynamic>? _systemInfo;

  int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) {
      return int.tryParse(value) ?? 0;
    }
    if (value == true) return 1;
    return 0;
  }

  @override
  void initState() {
    super.initState();
    _loadSystemInfo();
  }

  Future<void> _loadSystemInfo() async {
    setState(() => _isLoading = true);

    try {
      final response = await _apiService.getSystemResetInfo();
      setState(() {
        _systemInfo = response['data'];
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorDialog('خطأ في تحميل البيانات: $e');
    }
  }

  Future<void> _performReset(String resetType, String confirmationText) async {
    // تأكيد من المستخدم
    final confirmed = await _showConfirmationDialog(
      'تأكيد إعادة التهيئة',
      confirmationText,
    );

    if (!confirmed) return;

    setState(() => _isLoading = true);

    try {
      final response = await _apiService.resetSystem(resetType: resetType);

      setState(() => _isLoading = false);

      if (response['status'] == 'success') {
        _showSuccessDialog(response['message']);
        _loadSystemInfo(); // إعادة تحميل المعلومات
      } else {
        _showErrorDialog(response['message']);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      _showErrorDialog('خطأ: $e');
    }
  }

  Future<bool> _showConfirmationDialog(String title, String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Row(
              children: [
                Icon(Icons.warning, color: Colors.red.shade700, size: 28),
                SizedBox(width: 12),
                Text(title, style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(message, style: TextStyle(fontSize: 16)),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade300),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: Colors.red.shade700),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'هذا الإجراء لا يمكن التراجع عنه!',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.red.shade900,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text('إلغاء', style: TextStyle(fontSize: 16)),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red.shade700,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  'تأكيد الحذف',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showSuccessDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.check_circle, color: Colors.green.shade700, size: 28),
            SizedBox(width: 12),
            Text('نجح', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: TextStyle(fontSize: 16)),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green.shade700,
              foregroundColor: Colors.white,
            ),
            child: Text('حسناً', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  void _showErrorDialog(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            Icon(Icons.error, color: Colors.red.shade700, size: 28),
            SizedBox(width: 12),
            Text('خطأ', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(message, style: TextStyle(fontSize: 16)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('حسناً', style: TextStyle(fontSize: 16)),
          ),
        ],
      ),
    );
  }

  Widget _buildResetCard({
    required String title,
    required String description,
    required IconData icon,
    required Color color,
    required VoidCallback onPressed,
    required int itemCount,
  }) {
    return Card(
      elevation: 3,
      margin: EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: itemCount > 0 ? onPressed : null,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon, color: color, size: 32),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: color,
                          ),
                        ),
                        SizedBox(height: 4),
                        Text(
                          description,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              SizedBox(height: 12),
              Container(
                padding: EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: itemCount > 0
                      ? color.withValues(alpha: 0.1)
                      : Colors.grey.shade200,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  itemCount > 0 ? '$itemCount سجل' : 'لا توجد بيانات',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: itemCount > 0 ? color : Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final data = _systemInfo;
    final transactions =
        (data != null ? data['transactions'] as Map<String, dynamic>? : null) ??
        const <String, dynamic>{};
    final customersSuppliers =
        (data != null
            ? data['customers_suppliers'] as Map<String, dynamic>?
            : null) ??
        const <String, dynamic>{};
    final settingsData =
        (data != null ? data['settings'] as Map<String, dynamic>? : null) ??
        const <String, dynamic>{};
    final masterData =
        (data != null ? data['master_data'] as Map<String, dynamic>? : null) ??
        const <String, dynamic>{};

    final int journalEntries = _toInt(transactions['journal_entries']);
    final int invoicesCount = _toInt(transactions['invoices']);
    final int vouchersCount = _toInt(transactions['vouchers']);
    final int payrollCount = _toInt(transactions['payroll_entries']);
    final int attendanceCount = _toInt(transactions['attendance_records']);
    final int invoiceLinesCount = _toInt(transactions['invoice_items']);
    final int invoicePaymentsCount = _toInt(transactions['invoice_payments']);
    final int journalEntryLines = _toInt(transactions['journal_entry_lines']);
    final int voucherLines = _toInt(transactions['voucher_lines']);

    final int customersCount = _toInt(customersSuppliers['customers']);
    final int suppliersCount = _toInt(customersSuppliers['suppliers']);

    final bool hasSettings = settingsData['has_settings'] == true;

    final int accountsCount = _toInt(masterData['accounts']);
    final int itemsCount = _toInt(masterData['items']);
    final int goldPricesCount = _toInt(masterData['gold_prices']);
    final int paymentMethodsCount = _toInt(masterData['payment_methods']);
    final int safeBoxesCount = _toInt(masterData['safe_boxes']);
    final int employeesCount = _toInt(masterData['employees']);
    final int appUsersCount = _toInt(masterData['app_users']);
    final int mappingsCount = _toInt(masterData['accounting_mappings']);

    final int transactionsTotal =
        journalEntries +
        journalEntryLines +
        invoicesCount +
        invoiceLinesCount +
        invoicePaymentsCount +
        vouchersCount +
        voucherLines +
        payrollCount +
        attendanceCount;
    final int customersSuppliersTotal = customersCount + suppliersCount;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'إعادة تهيئة النظام',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.red.shade700,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(Icons.refresh),
            onPressed: _loadSystemInfo,
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator())
          : _systemInfo == null
          ? Center(child: Text('خطأ في تحميل البيانات'))
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // تحذير عام
                  Container(
                    margin: EdgeInsets.all(16),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: Colors.orange.shade300,
                        width: 2,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.warning_amber,
                          color: Colors.orange.shade700,
                          size: 36,
                        ),
                        SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'تحذير',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.orange.shade900,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'إعادة تهيئة النظام ستحذف البيانات بشكل نهائي ولا يمكن التراجع عنها.',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.orange.shade800,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  // خيارات إعادة التهيئة
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'اختر نوع إعادة التهيئة:',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey.shade800,
                      ),
                    ),
                  ),

                  // 1. حذف العمليات
                  _buildResetCard(
                    title: 'حذف العمليات',
                    description: 'حذف جميع القيود والفواتير والسندات',
                    icon: Icons.receipt_long,
                    color: Colors.blue.shade700,
                    itemCount: transactionsTotal,
                    onPressed: () => _performReset(
                      'transactions',
                      'سيتم حذف جميع العمليات (${journalEntries} قيد، ${journalEntryLines} سطر قيد، ${invoicesCount} فاتورة، ${invoiceLinesCount} بند فاتورة، ${invoicePaymentsCount} دفعة، ${vouchersCount} سند، ${voucherLines} سطر سند، ${payrollCount} سجل رواتب، ${attendanceCount} سجل حضور).\n\nستبقى بيانات العملاء والموردين والحسابات.',
                    ),
                  ),

                  // 2. حذف العملاء والموردين
                  _buildResetCard(
                    title: 'حذف العملاء والموردين',
                    description: 'حذف جميع بيانات العملاء والموردين',
                    icon: Icons.people,
                    color: Colors.purple.shade700,
                    itemCount: customersSuppliersTotal,
                    onPressed: () => _performReset(
                      'customers_suppliers',
                      'سيتم حذف جميع بيانات العملاء (${customersCount}) والموردين (${suppliersCount}).',
                    ),
                  ),

                  // 3. إعادة تعيين الإعدادات
                  _buildResetCard(
                    title: 'إعادة تعيين الإعدادات',
                    description: 'إرجاع جميع الإعدادات للقيم الافتراضية',
                    icon: Icons.settings_backup_restore,
                    color: Colors.orange.shade700,
                    itemCount: hasSettings ? 1 : 0,
                    onPressed: () => _performReset(
                      'settings',
                      'سيتم إعادة تعيين جميع الإعدادات للقيم الافتراضية (العيار الرئيسي، العملة، الضريبة، إلخ).',
                    ),
                  ),

                  // 4. إعادة تهيئة كاملة
                  _buildResetCard(
                    title: 'إعادة تهيئة كاملة',
                    description:
                        'حذف جميع البيانات وإعادة النظام لحالته الأولى',
                    icon: Icons.delete_forever,
                    color: Colors.red.shade700,
                    itemCount: 1, // دائماً متاح
                    onPressed: () => _performReset(
                      'all',
                      'سيتم حذف كل شيء:\n• جميع العمليات (${journalEntries} قيد، ${invoicesCount} فاتورة، ${vouchersCount} سند، ${payrollCount} سجل رواتب، ${attendanceCount} سجل حضور)\n• العملاء والموردين (${customersSuppliersTotal})\n• الحسابات (${accountsCount})\n• المواد (${itemsCount})\n• وسائل الدفع (${paymentMethodsCount})\n• الخزائن (${safeBoxesCount})\n• الإعدادات\n\nستحتاج إلى إعادة تحميل شجرة الحسابات بعد ذلك.',
                    ),
                  ),

                  SizedBox(height: 16),

                  // معلومات إضافية
                  Container(
                    margin: EdgeInsets.all(16),
                    padding: EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              color: Colors.blue.shade700,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'معلومات النظام',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade900,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 12),
                        _buildInfoRow('عدد الحسابات', '$accountsCount'),
                        _buildInfoRow('عدد المواد', '$itemsCount'),
                        _buildInfoRow('عدد أسعار الذهب', '$goldPricesCount'),
                        _buildInfoRow('وسائل الدفع', '$paymentMethodsCount'),
                        _buildInfoRow('الخزائن النشطة', '$safeBoxesCount'),
                        _buildInfoRow('عدد الموظفين', '$employeesCount'),
                        _buildInfoRow('حسابات النظام', '$appUsersCount'),
                        _buildInfoRow(
                          'إعدادات الربط المحاسبي',
                          '$mappingsCount',
                        ),
                        _buildInfoRow('سجلات الرواتب', '$payrollCount'),
                        _buildInfoRow('سجلات الحضور', '$attendanceCount'),
                      ],
                    ),
                  ),

                  SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
          ),
          Text(
            value,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.blue.shade800,
            ),
          ),
        ],
      ),
    );
  }
}
