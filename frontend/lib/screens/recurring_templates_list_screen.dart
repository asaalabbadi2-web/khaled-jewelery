import 'package:flutter/material.dart';
import '../api_service.dart';
import 'recurring_template_form.dart';

/// شاشة عرض قائمة القوالب الدورية
class RecurringTemplatesListScreen extends StatefulWidget {
  @override
  _RecurringTemplatesListScreenState createState() =>
      _RecurringTemplatesListScreenState();
}

class _RecurringTemplatesListScreenState
    extends State<RecurringTemplatesListScreen> {
  final ApiService _apiService = ApiService();
  List<dynamic> _templates = [];
  bool _isLoading = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchTemplates();
  }

  Future<void> _fetchTemplates() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final templates = await _apiService.get('/recurring_templates');
      if (mounted) {
        setState(() {
          _templates = templates;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
        _showErrorSnackBar('فشل تحميل القوالب: $e');
      }
    }
  }

  Future<void> _toggleActive(int templateId, bool currentStatus) async {
    try {
      await _apiService.post(
        '/recurring_templates/$templateId/toggle_active',
        {},
      );
      _fetchTemplates();
      _showSuccessSnackBar(
        currentStatus ? 'تم إيقاف القالب' : 'تم تفعيل القالب',
      );
    } catch (e) {
      _showErrorSnackBar('فشل تغيير حالة القالب: $e');
    }
  }

  Future<void> _deleteTemplate(int templateId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('تأكيد الحذف'),
          content: Text('هل أنت متأكد من حذف هذا القالب؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              child: Text('حذف'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await _apiService.delete('/recurring_templates/$templateId');
        _fetchTemplates();
        _showSuccessSnackBar('تم حذف القالب بنجاح');
      } catch (e) {
        _showErrorSnackBar('فشل حذف القالب: $e');
      }
    }
  }

  Future<void> _createEntry(int templateId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('إنشاء قيد'),
          content: Text('هل تريد إنشاء قيد الآن من هذا القالب؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('إلغاء'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: Color(0xFFD4AF37),
              ),
              child: Text('إنشاء'),
            ),
          ],
        ),
      ),
    );

    if (confirmed == true) {
      try {
        await _apiService.post(
          '/recurring_templates/$templateId/create_entry',
          {},
        );
        _showSuccessSnackBar('تم إنشاء القيد بنجاح');
        _fetchTemplates();
      } catch (e) {
        _showErrorSnackBar('فشل إنشاء القيد: $e');
      }
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ),
    );
  }

  void _showSuccessSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );
  }

  List<dynamic> get _filteredTemplates {
    if (_searchQuery.isEmpty) {
      return _templates;
    }
    return _templates.where((template) {
      final name = template['name']?.toString().toLowerCase() ?? '';
      final description =
          template['description']?.toString().toLowerCase() ?? '';
      final query = _searchQuery.toLowerCase();
      return name.contains(query) || description.contains(query);
    }).toList();
  }

  String _getFrequencyText(String frequency) {
    switch (frequency) {
      case 'daily':
        return 'يومي';
      case 'weekly':
        return 'أسبوعي';
      case 'monthly':
        return 'شهري';
      case 'quarterly':
        return 'ربع سنوي';
      case 'yearly':
        return 'سنوي';
      default:
        return frequency;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            'القوالب الدورية',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          backgroundColor: Color(0xFFD4AF37),
          actions: [
            IconButton(
              icon: Icon(Icons.refresh),
              onPressed: _fetchTemplates,
              tooltip: 'تحديث',
            ),
          ],
        ),
        body: Column(
          children: [
            _buildSearchBar(),
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator())
                  : _filteredTemplates.isEmpty
                      ? _buildEmptyState()
                      : _buildTemplatesList(),
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () async {
            final result = await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => RecurringTemplateFormScreen(),
              ),
            );
            if (result == true) {
              _fetchTemplates();
            }
          },
          icon: Icon(Icons.add),
          label: Text('إضافة قالب'),
          backgroundColor: Color(0xFFD4AF37),
        ),
      ),
    );
  }

  Widget _buildSearchBar() {
    return Container(
      padding: EdgeInsets.all(16),
      color: Colors.white,
      child: TextField(
        decoration: InputDecoration(
          hintText: 'البحث عن قالب...',
          prefixIcon: Icon(Icons.search, color: Color(0xFFD4AF37)),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Color(0xFFD4AF37)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Color(0xFFD4AF37), width: 2),
          ),
        ),
        onChanged: (value) {
          setState(() {
            _searchQuery = value;
          });
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.repeat_rounded,
            size: 80,
            color: Colors.grey[300],
          ),
          SizedBox(height: 16),
          Text(
            'لا توجد قوالب دورية',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[600],
              fontWeight: FontWeight.bold,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'اضغط على الزر أدناه لإضافة قالب جديد',
            style: TextStyle(color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  Widget _buildTemplatesList() {
    return ListView.builder(
      padding: EdgeInsets.all(16),
      itemCount: _filteredTemplates.length,
      itemBuilder: (context, index) {
        final template = _filteredTemplates[index];
        return _buildTemplateCard(template);
      },
    );
  }

  Widget _buildTemplateCard(dynamic template) {
    final isActive = template['is_active'] ?? false;
    final autoCreate = template['auto_create'] ?? false;

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActive ? Color(0xFFD4AF37).withValues(alpha: 0.3) : Colors.grey.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: () async {
          final result = await Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => RecurringTemplateFormScreen(
                template: template,
                isEditMode: true,
              ),
            ),
          );
          if (result == true) {
            _fetchTemplates();
          }
        },
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          template['name'] ?? 'قالب بدون اسم',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isActive ? Colors.black87 : Colors.grey,
                          ),
                        ),
                        if (template['description'] != null &&
                            template['description'].isNotEmpty)
                          Padding(
                            padding: EdgeInsets.only(top: 4),
                            child: Text(
                              template['description'],
                              style: TextStyle(
                                fontSize: 14,
                                color: Colors.grey[600],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  PopupMenuButton(
                    icon: Icon(Icons.more_vert),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            Icon(Icons.edit, size: 20, color: Colors.blue),
                            SizedBox(width: 8),
                            Text('تعديل'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'toggle',
                        child: Row(
                          children: [
                            Icon(
                              isActive ? Icons.pause : Icons.play_arrow,
                              size: 20,
                              color: isActive ? Colors.orange : Colors.green,
                            ),
                            SizedBox(width: 8),
                            Text(isActive ? 'إيقاف' : 'تفعيل'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'create',
                        child: Row(
                          children: [
                            Icon(Icons.add_circle,
                                size: 20, color: Color(0xFFD4AF37)),
                            SizedBox(width: 8),
                            Text('إنشاء قيد الآن'),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete, size: 20, color: Colors.red),
                            SizedBox(width: 8),
                            Text('حذف'),
                          ],
                        ),
                      ),
                    ],
                    onSelected: (value) {
                      if (value == 'edit') {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => RecurringTemplateFormScreen(
                              template: template,
                              isEditMode: true,
                            ),
                          ),
                        ).then((result) {
                          if (result == true) {
                            _fetchTemplates();
                          }
                        });
                      } else if (value == 'toggle') {
                        _toggleActive(template['id'], isActive);
                      } else if (value == 'create') {
                        _createEntry(template['id']);
                      } else if (value == 'delete') {
                        _deleteTemplate(template['id']);
                      }
                    },
                  ),
                ],
              ),
              Divider(height: 24),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _buildInfoChip(
                    Icons.repeat,
                    _getFrequencyText(template['frequency'] ?? ''),
                    Color(0xFFD4AF37),
                  ),
                  if (template['interval'] != null &&
                      template['interval'] > 1)
                    _buildInfoChip(
                      Icons.numbers,
                      'كل ${template['interval']}',
                      Colors.blue,
                    ),
                  _buildInfoChip(
                    isActive ? Icons.check_circle : Icons.pause_circle,
                    isActive ? 'نشط' : 'متوقف',
                    isActive ? Colors.green : Colors.orange,
                  ),
                  if (autoCreate)
                    _buildInfoChip(
                      Icons.auto_awesome,
                      'تلقائي',
                      Colors.purple,
                    ),
                  if (template['total_created'] != null &&
                      template['total_created'] > 0)
                    _buildInfoChip(
                      Icons.task_alt,
                      '${template['total_created']} قيد',
                      Colors.teal,
                    ),
                ],
              ),
              if (template['next_run_date'] != null) ...[
                SizedBox(height: 12),
                Container(
                  padding: EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  decoration: BoxDecoration(
                    color: Color(0xFFD4AF37).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.schedule,
                        size: 16,
                        color: Color(0xFFD4AF37),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'التشغيل القادم: ${template['next_run_date'].split('T').first}',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.black87,
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
    );
  }

  Widget _buildInfoChip(IconData icon, String label, Color color) {
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color.withValues(alpha: 0.9),
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}
