import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import '../theme/app_theme.dart';
import 'recurring_template_form.dart';

class RecurringTemplatesScreen extends StatefulWidget {
  final bool isArabic;

  const RecurringTemplatesScreen({
    Key? key,
    this.isArabic = true,
  }) : super(key: key);

  @override
  State<RecurringTemplatesScreen> createState() => _RecurringTemplatesScreenState();
}

class _RecurringTemplatesScreenState extends State<RecurringTemplatesScreen> {
  final String _baseUrl = 'http://127.0.0.1:8001';
  List<Map<String, dynamic>> templates = [];
  bool isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    setState(() => isLoading = true);
    try {
      final response = await http.get(
        Uri.parse('$_baseUrl/api/recurring_templates'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          templates = data.map((e) => e as Map<String, dynamic>).toList();
          isLoading = false;
        });
      } else {
        throw Exception('فشل تحميل القوالب');
      }
    } catch (e) {
      setState(() => isLoading = false);
      if (mounted) {
        final theme = Theme.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: theme.colorScheme.error,
            content: Text(
              'خطأ في تحميل القوالب: $e',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onError),
            ),
          ),
        );
      }
    }
  }

  Future<void> _openTemplateForm({
    Map<String, dynamic>? template,
    bool isEditMode = false,
  }) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RecurringTemplateFormScreen(
          template: template,
          isEditMode: isEditMode,
        ),
      ),
    );

    if (result == true) {
      _loadTemplates();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(isAr ? 'القيود الدورية' : 'Recurring Templates'),
        centerTitle: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openTemplateForm(),
        icon: Icon(Icons.add),
        label: Text(isAr ? 'إضافة قالب جديد' : 'Add Template'),
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
      ),
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              colorScheme.surface,
              theme.scaffoldBackgroundColor,
            ],
          ),
        ),
        child: isLoading
            ? Center(
                child: CircularProgressIndicator(color: colorScheme.primary),
              )
            : templates.isEmpty
                ? _buildEmptyState(isAr, theme)
                : _buildTemplatesList(isAr, theme),
      ),
    );
  }

  Widget _buildEmptyState(bool isAr, ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.repeat,
            size: 80,
            color: theme.colorScheme.primary.withValues(alpha: 0.25),
          ),
          SizedBox(height: 16),
          Text(
            isAr ? 'لا توجد قوالب دورية' : 'No Recurring Templates',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
            ),
          ),
          SizedBox(height: 8),
          Text(
            isAr
                ? 'اضغط على الزر أدناه لإضافة قالب جديد'
                : 'Tap the button below to add a new template',
            style: TextStyle(
              color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildTemplatesList(bool isAr, ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _loadTemplates,
      child: ListView.builder(
        padding: EdgeInsets.all(16),
        itemCount: templates.length,
        itemBuilder: (context, index) {
          final template = templates[index];
          return _buildTemplateCard(template, isAr, theme);
        },
      ),
    );
  }

  Widget _buildTemplateCard(
      Map<String, dynamic> template, bool isAr, ThemeData theme) {
    final isActive = template['is_active'] ?? false;
    final name = template['name'] ?? '';
    final frequencyText = template['frequency_text'] ?? '';
    final nextRunDate = template['next_run_date'] ?? '';
    final totalCreated = template['total_created'] ?? 0;
    final lastCreatedDate = template['last_created_date'];
    final colorScheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.only(bottom: 12),
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: () => _openTemplateForm(
          template: template,
          isEditMode: true,
        ),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              Row(
                children: [
                  CircleAvatar(
                    backgroundColor:
                        isActive ? AppColors.success : theme.disabledColor,
                    radius: 20,
                    child: Icon(Icons.repeat, color: Colors.white, size: 20),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: theme.colorScheme.onSurface,
                          ),
                        ),
                        SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              padding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isActive
                                    ? AppColors.success.withValues(alpha: 0.12)
                                    : theme.colorScheme.surfaceVariant,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isActive
                                      ? AppColors.success
                                      : theme.dividerColor,
                                ),
                              ),
                              child: Text(
                                isActive
                                    ? (isAr ? 'نشط' : 'Active')
                                    : (isAr ? 'متوقف' : 'Inactive'),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: isActive
                                      ? AppColors.success
                                      : theme.colorScheme.onSurface
                                          .withValues(alpha: 0.6),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              frequencyText,
                              style: TextStyle(
                                fontSize: 12,
                                color:
                                    theme.colorScheme.onSurface.withValues(alpha: 0.6),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              
              SizedBox(height: 12),
              Divider(height: 1),
              SizedBox(height: 12),
              
              // Info
              Row(
                children: [
                  Icon(
                    Icons.calendar_today,
                    size: 16,
                    color: AppColors.darkGold,
                  ),
                  SizedBox(width: 6),
                  Text(
                    isAr ? 'التالي: ' : 'Next: ',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    _formatDate(nextRunDate),
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.darkGold,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              
              SizedBox(height: 6),
              
              Row(
                children: [
                  Icon(
                    Icons.check_circle,
                    size: 16,
                    color: AppColors.success,
                  ),
                  SizedBox(width: 6),
                  Text(
                    isAr ? 'تم إنشاء: ' : 'Created: ',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  Text(
                    '$totalCreated ${isAr ? 'قيد' : 'entries'}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: AppColors.success,
                    ),
                  ),
                ],
              ),
              
              if (lastCreatedDate != null) ...[
                SizedBox(height: 4),
                Text(
                  '${isAr ? 'آخر إنشاء:' : 'Last created:'} ${_formatDate(lastCreatedDate)}',
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
              
              SizedBox(height: 12),
              
              // Actions
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _createEntryNow(template['id'], isAr),
                      icon: Icon(Icons.play_arrow, size: 18),
                      label: Text(
                        isAr ? 'إنشاء الآن' : 'Create Now',
                        style: TextStyle(fontSize: 13),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primaryGold,
                        foregroundColor: colorScheme.onPrimary,
                        padding: EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _openTemplateForm(
                        template: template,
                        isEditMode: true,
                      ),
                      icon: Icon(Icons.edit, size: 18),
                      label: Text(
                        isAr ? 'تعديل' : 'Edit',
                        style: TextStyle(fontSize: 13),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: colorScheme.primary,
                        side: BorderSide(color: colorScheme.primary),
                        padding: EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  IconButton(
                    onPressed: () => _showOptionsMenu(template, isAr),
                    icon: Icon(Icons.more_vert, color: colorScheme.primary),
                    tooltip: isAr ? 'المزيد' : 'More',
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showOptionsMenu(Map<String, dynamic> template, bool isAr) {
    showModalBottomSheet(
      context: context,
      builder: (context) {
        final theme = Theme.of(context);
        final colorScheme = theme.colorScheme;
        return SafeArea(
          child: Container(
            color: colorScheme.surface,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(Icons.edit, color: colorScheme.primary),
                title: Text(
                  isAr ? 'تعديل القالب' : 'Edit Template',
                ),
                onTap: () {
                  Navigator.pop(context);
                  _openTemplateForm(
                    template: template,
                    isEditMode: true,
                  );
                },
              ),
              ListTile(
                leading: Icon(
                  template['is_active'] ? Icons.pause : Icons.play_arrow,
                  color: AppColors.warning,
                ),
                title: Text(
                  template['is_active']
                      ? (isAr ? 'تعطيل القالب' : 'Deactivate')
                      : (isAr ? 'تفعيل القالب' : 'Activate'),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _toggleActive(template['id'], isAr);
                },
              ),
              ListTile(
                leading: Icon(Icons.delete, color: AppColors.error),
                title: Text(
                  isAr ? 'حذف القالب' : 'Delete Template',
                  style: TextStyle(color: AppColors.error),
                ),
                onTap: () {
                  Navigator.pop(context);
                  _confirmDelete(template, isAr);
                },
              ),
            ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _createEntryNow(int templateId, bool isAr) async {
    try {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => Center(
          child: Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  SizedBox(height: 16),
                  Text(
                    isAr ? 'جاري إنشاء القيد...' : 'Creating entry...',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      final response = await http.post(
        Uri.parse('$_baseUrl/api/recurring_templates/$templateId/create_entry'),
      );

      Navigator.pop(context); // Close loading

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final entryNumber = data['entry']?['entry_number'] ?? '';
        
        final theme = Theme.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.success,
            duration: Duration(seconds: 3),
            content: Text(
              isAr
                  ? 'تم إنشاء القيد $entryNumber بنجاح'
                  : 'Entry $entryNumber created successfully',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onPrimary),
            ),
          ),
        );
        
        _loadTemplates(); // Refresh list
      } else {
        throw Exception('Failed to create entry');
      }
    } catch (e) {
      Navigator.pop(context);
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.error,
          content: Text(
            isAr ? 'خطأ: $e' : 'Error: $e',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onError),
          ),
        ),
      );
    }
  }

  Future<void> _toggleActive(int templateId, bool isAr) async {
    try {
      final response = await http.post(
        Uri.parse('$_baseUrl/api/recurring_templates/$templateId/toggle_active'),
      );

      if (response.statusCode == 200) {
        final theme = Theme.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.primaryGold,
            content: Text(
              isAr ? 'تم تغيير حالة القالب' : 'Template status changed',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onPrimary),
            ),
          ),
        );
        _loadTemplates();
      }
    } catch (e) {
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: AppColors.error,
          content: Text(
            isAr ? 'خطأ: $e' : 'Error: $e',
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.onError),
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(Map<String, dynamic> template, bool isAr) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          isAr ? 'تأكيد الحذف' : 'Confirm Delete',
          style: Theme.of(context)
              .textTheme
              .titleLarge
              ?.copyWith(color: AppColors.error),
        ),
        content: Text(
          isAr
              ? 'هل تريد حذف قالب "${template['name']}"؟'
              : 'Delete template "${template['name']}"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(isAr ? 'إلغاء' : 'Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              isAr ? 'حذف' : 'Delete',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        final response = await http.delete(
          Uri.parse('$_baseUrl/api/recurring_templates/${template['id']}'),
        );

        if (response.statusCode == 200) {
          final theme = Theme.of(context);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: AppColors.success,
              content: Text(
                isAr ? 'تم حذف القالب' : 'Template deleted',
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onPrimary),
              ),
            ),
          );
          _loadTemplates();
        }
      } catch (e) {
        final theme = Theme.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.error,
            content: Text(
              isAr ? 'خطأ: $e' : 'Error: $e',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onError),
            ),
          ),
        );
      }
    }
  }

  String _formatDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return '-';
    try {
      final date = DateTime.parse(dateStr);
      return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    } catch (e) {
      return dateStr;
    }
  }
}
