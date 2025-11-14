import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../api_service.dart';

/// شاشة سجل التدقيق (Audit Log Screen)
/// تعرض جميع العمليات الحساسة في النظام لأغراض المراجعة والتدقيق المحاسبي
class AuditLogScreen extends StatefulWidget {
  const AuditLogScreen({super.key});

  @override
  State<AuditLogScreen> createState() => _AuditLogScreenState();
}

class _AuditLogScreenState extends State<AuditLogScreen> {
  final ApiService _apiService = ApiService();
  
  List<dynamic> _logs = [];
  bool _isLoading = false;
  
  // Filters
  String? _filterUserName;
  String? _filterAction;
  String? _filterEntityType;
  bool? _filterSuccess;
  
  // Statistics
  Map<String, dynamic>? _stats;
  bool _isLoadingStats = false;

  @override
  void initState() {
    super.initState();
    _loadAuditLogs();
    _loadStats();
  }

  Future<void> _loadAuditLogs() async {
    setState(() => _isLoading = true);
    try {
      final data = await _apiService.getAuditLogs(
        userName: _filterUserName,
        action: _filterAction,
        entityType: _filterEntityType,
        success: _filterSuccess,
        limit: 100,
      );
      
      if (mounted) {
        setState(() {
          _logs = data['logs'] ?? [];
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في تحميل سجل التدقيق: ${e.toString()}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadStats() async {
    if (mounted) setState(() => _isLoadingStats = true);
    try {
      final data = await _apiService.getAuditStats();
      if (mounted) {
        setState(() {
          _stats = data['stats'];
          _isLoadingStats = false;
        });
      }
    } catch (e) {
      debugPrint('خطأ في تحميل إحصائيات سجل التدقيق: $e');
      if (mounted) setState(() => _isLoadingStats = false);
    }
  }

  void _showFilterDialog() {
    showDialog(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('تصفية السجلات'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  decoration: const InputDecoration(labelText: 'اسم المستخدم'),
                  onChanged: (value) => _filterUserName = value.isEmpty ? null : value,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'نوع العملية'),
                  value: _filterAction,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('الكل')),
                    DropdownMenuItem(value: 'post_invoice', child: Text('ترحيل فاتورة')),
                    DropdownMenuItem(value: 'unpost_invoice', child: Text('إلغاء ترحيل فاتورة')),
                    DropdownMenuItem(value: 'post_entry', child: Text('ترحيل قيد')),
                    DropdownMenuItem(value: 'unpost_entry', child: Text('إلغاء ترحيل قيد')),
                  ],
                  onChanged: (value) => _filterAction = value,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  decoration: const InputDecoration(labelText: 'نوع الكيان'),
                  value: _filterEntityType,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('الكل')),
                    DropdownMenuItem(value: 'Invoice', child: Text('فاتورة')),
                    DropdownMenuItem(value: 'JournalEntry', child: Text('قيد يومية')),
                  ],
                  onChanged: (value) => _filterEntityType = value,
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<bool>(
                  decoration: const InputDecoration(labelText: 'الحالة'),
                  value: _filterSuccess,
                  items: const [
                    DropdownMenuItem(value: null, child: Text('الكل')),
                    DropdownMenuItem(value: true, child: Text('نجحت')),
                    DropdownMenuItem(value: false, child: Text('فشلت')),
                  ],
                  onChanged: (value) => _filterSuccess = value,
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _filterUserName = null;
                  _filterAction = null;
                  _filterEntityType = null;
                  _filterSuccess = null;
                });
                Navigator.pop(context);
                _loadAuditLogs();
              },
              child: const Text('إعادة تعيين'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _loadAuditLogs();
              },
              child: const Text('تطبيق'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('سجل التدقيق'),
          backgroundColor: const Color(0xFFFFD700),
          actions: [
            IconButton(
              icon: const Icon(Icons.filter_list),
              onPressed: _showFilterDialog,
              tooltip: 'تصفية',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _loadAuditLogs();
                _loadStats();
              },
              tooltip: 'تحديث',
            ),
          ],
        ),
        body: Column(
          children: [
            // Statistics Card
            if (_stats != null) _buildStatsCard(),
            
            // Logs List
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _logs.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.history, size: 64, color: Colors.grey),
                              SizedBox(height: 16),
                              Text(
                                'لا توجد سجلات تدقيق',
                                style: TextStyle(fontSize: 18, color: Colors.grey),
                              ),
                            ],
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(8),
                          itemCount: _logs.length,
                          itemBuilder: (context, index) {
                            final log = _logs[index];
                            return _buildLogCard(log);
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatsCard() {
    return Card(
      margin: const EdgeInsets.all(16),
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.analytics, color: Color(0xFFFFD700)),
                SizedBox(width: 8),
                Text(
                  'إحصائيات سجل التدقيق',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _buildStatItem(
                  'إجمالي السجلات',
                  _stats!['total_logs'].toString(),
                  Icons.list,
                  Colors.blue,
                ),
                _buildStatItem(
                  'الناجحة',
                  _stats!['successful'].toString(),
                  Icons.check_circle,
                  Colors.green,
                ),
                _buildStatItem(
                  'الفاشلة',
                  _stats!['failed'].toString(),
                  Icons.error,
                  Colors.red,
                ),
                _buildStatItem(
                  'اليوم',
                  _stats!['logs_today'].toString(),
                  Icons.today,
                  Colors.orange,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 32),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        Text(
          label,
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildLogCard(Map<String, dynamic> log) {
    final success = log['success'] as bool;
    final timestamp = DateTime.parse(log['timestamp']);
    
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: success ? Colors.green : Colors.red,
          child: Icon(
            success ? Icons.check : Icons.close,
            color: Colors.white,
          ),
        ),
        title: Text(
          '${log['action_ar']} - ${log['entity_type_ar']} #${log['entity_id']}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('المستخدم: ${log['user_name']}'),
            Text('الوقت: ${_formatDateTime(timestamp)}'),
            if (log['entity_number'] != null)
              Text('رقم الكيان: ${log['entity_number']}'),
            if (log['ip_address'] != null)
              Text('IP: ${log['ip_address']}'),
            if (!success && log['error_message'] != null)
              Text(
                'الخطأ: ${log['error_message']}',
                style: const TextStyle(color: Colors.red),
              ),
          ],
        ),
        trailing: IconButton(
          icon: const Icon(Icons.info_outline),
          onPressed: () => _showLogDetails(log),
        ),
      ),
    );
  }

  void _showLogDetails(Map<String, dynamic> log) {
    showDialog(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تفاصيل السجل #${log['id']}'),
          content: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDetailRow('المستخدم', log['user_name']),
                _buildDetailRow('العملية', log['action_ar']),
                _buildDetailRow('نوع الكيان', log['entity_type_ar']),
                _buildDetailRow('معرف الكيان', log['entity_id'].toString()),
                if (log['entity_number'] != null)
                  _buildDetailRow('رقم الكيان', log['entity_number']),
                _buildDetailRow('الوقت', _formatDateTime(DateTime.parse(log['timestamp']))),
                if (log['ip_address'] != null)
                  _buildDetailRow('عنوان IP', log['ip_address']),
                _buildDetailRow('الحالة', log['success'] ? 'نجحت' : 'فشلت'),
                if (log['error_message'] != null)
                  _buildDetailRow('رسالة الخطأ', log['error_message']),
                if (log['details'] != null) ...[
                  const Divider(),
                  const Text(
                    'التفاصيل:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(log['details']),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إغلاق'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(
            child: Text(value),
          ),
        ],
      ),
    );
  }

  String _formatDateTime(DateTime dateTime) {
    return DateFormat('yyyy-MM-dd HH:mm:ss').format(dateTime);
  }
}
