import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';
import '../utils/arabic_number_formatter.dart';

/// شاشة إضافة/تعديل قالب قيد دوري
class RecurringTemplateFormScreen extends StatefulWidget {
  final dynamic template;
  final bool isEditMode;

  const RecurringTemplateFormScreen({
    super.key,
    this.template,
    this.isEditMode = false,
  });

  @override
  State<RecurringTemplateFormScreen> createState() =>
      _RecurringTemplateFormScreenState();
}

class _RecurringTemplateFormScreenState
    extends State<RecurringTemplateFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final ApiService _apiService = ApiService();

  // Controllers
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _startDateController;
  late TextEditingController _endDateController;
  late TextEditingController _intervalController;
  late TextEditingController _preferredDayController;

  // State variables
  String _selectedFrequency = 'monthly';
  bool _isActive = true;
  bool _autoCreate = true;
  List<dynamic> _accounts = [];
  List<RecurringTemplateLine> _lines = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();

    _nameController = TextEditingController(
      text: widget.template?['name'] ?? '',
    );
    _descriptionController = TextEditingController(
      text: widget.template?['description'] ?? '',
    );
    _startDateController = TextEditingController(
      text:
          widget.template?['start_date']?.split('T').first ??
          DateTime.now().toIso8601String().split('T').first,
    );
    _endDateController = TextEditingController(
      text: widget.template?['end_date']?.split('T').first ?? '',
    );
    _intervalController = TextEditingController(
      text: (widget.template?['interval'] ?? 1).toString(),
    );
    _preferredDayController = TextEditingController(
      text: (widget.template?['preferred_day_of_month'] ?? 1).toString(),
    );

    _selectedFrequency = widget.template?['frequency'] ?? 'monthly';
    _isActive = widget.template?['is_active'] ?? true;
    _autoCreate = widget.template?['auto_create'] ?? true;

    final existingLines = widget.template != null
        ? (widget.template['template_lines'] ?? widget.template['lines'])
        : null;

    if (existingLines != null && existingLines is List) {
      _lines = existingLines
          .map((line) => RecurringTemplateLine.fromMap(line))
          .toList();
    } else {
      // إضافة سطرين فارغين للبداية
      _lines.add(RecurringTemplateLine());
      _lines.add(RecurringTemplateLine());
    }

    _fetchAccounts();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _startDateController.dispose();
    _endDateController.dispose();
    _intervalController.dispose();
    _preferredDayController.dispose();
    for (var line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  Future<void> _fetchAccounts() async {
    try {
      final accounts = await _apiService.getAccounts();
      if (mounted) {
        setState(() {
          _accounts = accounts;
        });
      }
    } catch (e) {
      _showErrorSnackBar('فشل تحميل الحسابات: $e');
    }
  }

  void _addLine() {
    setState(() {
      _lines.add(RecurringTemplateLine());
    });
  }

  void _removeLine(int index) {
    if (_lines.length > 1) {
      setState(() {
        _lines[index].dispose();
        _lines.removeAt(index);
      });
    }
  }

  Future<void> _selectDate(TextEditingController controller) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(primary: AppColors.primaryGold),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() {
        controller.text = DateFormat('yyyy-MM-dd').format(picked);
      });
    }
  }

  Future<void> _saveTemplate() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    // التحقق من وجود سطر واحد على الأقل بحساب
    final validLines = _lines.where((line) => line.accountId != null).toList();
    if (validLines.isEmpty) {
      _showErrorSnackBar('يجب إضافة سطر واحد على الأقل مع تحديد الحساب');
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      final data = {
        'name': _nameController.text.trim(),
        'description': _descriptionController.text.trim(),
        'frequency': _selectedFrequency,
        'interval': int.parse(_intervalController.text),
        'start_date': _startDateController.text,
        'end_date': _endDateController.text.isEmpty
            ? null
            : _endDateController.text,
        'preferred_day_of_month': int.parse(_preferredDayController.text),
        'is_active': _isActive,
        'auto_create': _autoCreate,
        'lines': validLines
            .map(
              (line) => {
                'account_id': line.accountId,
                'cash_debit': line.cashDebit,
                'cash_credit': line.cashCredit,
                'debit_21k': line.goldDebit,
                'credit_21k': line.goldCredit,
                'description': line.description,
              },
            )
            .toList(),
      };

      if (widget.isEditMode) {
        await _apiService.put(
          '/recurring_templates/${widget.template['id']}',
          data,
        );
      } else {
        await _apiService.post('/recurring_templates', data);
      }

      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      _showErrorSnackBar('فشل حفظ القالب: $e');
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: AppColors.error,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.isEditMode ? 'تعديل قالب قيد دوري' : 'إضافة قالب قيد دوري',
            style: textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.bold,
              color: colorScheme.onPrimary,
            ),
          ),
          backgroundColor: colorScheme.primary,
          actions: [
            if (_isLoading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              )
            else
              IconButton(
                icon: const Icon(Icons.save),
                onPressed: _saveTemplate,
                tooltip: 'حفظ',
              ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _buildBasicInfoSection(),
              const SizedBox(height: 20),
              _buildFrequencySection(),
              const SizedBox(height: 20),
              _buildDatesSection(),
              const SizedBox(height: 20),
              _buildSettingsSection(),
              const SizedBox(height: 20),
              _buildLinesSection(),
              const SizedBox(height: 20),
              _buildSaveButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBasicInfoSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'المعلومات الأساسية',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'اسم القالب *',
                hintText: 'مثل: راتب موظفي المحل',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: Icon(Icons.label, color: colorScheme.primary),
              ),
              validator: (value) {
                if (value == null || value.trim().isEmpty) {
                  return 'الرجاء إدخال اسم القالب';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              decoration: InputDecoration(
                labelText: 'الوصف',
                hintText: 'وصف اختياري للقالب',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: Icon(Icons.description, color: colorScheme.primary),
              ),
              maxLines: 3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFrequencySection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'التكرار',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedFrequency,
                    decoration: InputDecoration(
                      labelText: 'نوع التكرار *',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      prefixIcon: Icon(
                        Icons.repeat,
                        color: colorScheme.primary,
                      ),
                    ),
                    items: const [
                      DropdownMenuItem(value: 'daily', child: Text('يومي')),
                      DropdownMenuItem(value: 'weekly', child: Text('أسبوعي')),
                      DropdownMenuItem(value: 'monthly', child: Text('شهري')),
                      DropdownMenuItem(
                        value: 'quarterly',
                        child: Text('ربع سنوي'),
                      ),
                      DropdownMenuItem(value: 'yearly', child: Text('سنوي')),
                    ],
                    onChanged: (value) {
                      setState(() {
                        _selectedFrequency = value!;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    controller: _intervalController,
                    decoration: InputDecoration(
                      labelText: 'كل',
                      hintText: '1',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: const [ArabicNumberTextInputFormatter()],
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'مطلوب';
                      }
                      final num = int.tryParse(value);
                      if (num == null || num < 1) {
                        return 'أدخل رقم صحيح';
                      }
                      return null;
                    },
                  ),
                ),
              ],
            ),
            if (_selectedFrequency == 'monthly') ...[
              const SizedBox(height: 16),
              TextFormField(
                controller: _preferredDayController,
                decoration: InputDecoration(
                  labelText: 'اليوم المفضل من الشهر',
                  hintText: '1-31',
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  prefixIcon: Icon(
                    Icons.calendar_today,
                    color: colorScheme.primary,
                  ),
                  helperText: 'اليوم من الشهر (1 = أول يوم)',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: const [ArabicNumberTextInputFormatter()],
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return null;
                  }
                  final num = int.tryParse(value);
                  if (num == null || num < 1 || num > 31) {
                    return 'أدخل رقم بين 1 و 31';
                  }
                  return null;
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDatesSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'التواريخ',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _startDateController,
              decoration: InputDecoration(
                labelText: 'تاريخ البداية *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: Icon(
                  Icons.calendar_today,
                  color: colorScheme.primary,
                ),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.edit_calendar),
                  onPressed: () => _selectDate(_startDateController),
                ),
              ),
              readOnly: true,
              onTap: () => _selectDate(_startDateController),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'الرجاء تحديد تاريخ البداية';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _endDateController,
              decoration: InputDecoration(
                labelText: 'تاريخ النهاية (اختياري)',
                hintText: 'اتركه فارغاً للاستمرار بدون نهاية',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                prefixIcon: Icon(Icons.event_busy, color: colorScheme.primary),
                suffixIcon: _endDateController.text.isNotEmpty
                    ? Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setState(() {
                                _endDateController.clear();
                              });
                            },
                          ),
                          IconButton(
                            icon: const Icon(Icons.edit_calendar),
                            onPressed: () => _selectDate(_endDateController),
                          ),
                        ],
                      )
                    : IconButton(
                        icon: const Icon(Icons.edit_calendar),
                        onPressed: () => _selectDate(_endDateController),
                      ),
              ),
              readOnly: true,
              onTap: () => _selectDate(_endDateController),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsSection() {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final textTheme = theme.textTheme;
    final subtitleStyle = textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
    );

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'الإعدادات',
              style: textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 12),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text('القالب نشط', style: textTheme.titleMedium),
              subtitle: Text('تفعيل/إيقاف القالب', style: subtitleStyle),
              value: _isActive,
              activeThumbColor: colorScheme.primary,
              onChanged: (value) {
                setState(() {
                  _isActive = value;
                });
              },
            ),
            const Divider(),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text('إنشاء تلقائي', style: textTheme.titleMedium),
              subtitle: Text(
                'إنشاء القيود تلقائياً في المواعيد المحددة',
                style: subtitleStyle,
              ),
              value: _autoCreate,
              activeThumbColor: colorScheme.primary,
              onChanged: (value) {
                setState(() {
                  _autoCreate = value;
                });
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLinesSection() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'سطور القيد',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _addLine,
                  icon: Icon(Icons.add, size: 18),
                  label: Text('إضافة سطر'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            ..._lines.asMap().entries.map((entry) {
              final index = entry.key;
              final line = entry.value;
              return _buildLineCard(index, line);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildLineCard(int index, RecurringTemplateLine line) {
    return Card(
      margin: EdgeInsets.only(bottom: 12),
      color: Colors.grey[50],
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'سطر ${index + 1}',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (_lines.length > 1)
                  IconButton(
                    icon: Icon(Icons.delete, color: Colors.red),
                    onPressed: () => _removeLine(index),
                    iconSize: 20,
                  ),
              ],
            ),
            SizedBox(height: 8),
            DropdownButtonFormField<int>(
              initialValue: line.accountId,
              decoration: InputDecoration(
                labelText: 'الحساب *',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: _accounts
                  .map(
                    (acc) => DropdownMenuItem<int>(
                      value: acc['id'],
                      child: Text(
                        '${acc['number']} - ${acc['name']}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (value) {
                setState(() {
                  line.accountId = value;
                });
              },
            ),
            SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: line.cashDebitController,
                    decoration: InputDecoration(
                      labelText: 'مدين نقد',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: const EdgeInsets.all(8),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [ArabicNumberTextInputFormatter()],
                    onChanged: (value) {
                      line.cashDebit = double.tryParse(value) ?? 0.0;
                    },
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: line.cashCreditController,
                    decoration: InputDecoration(
                      labelText: 'دائن نقد',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: EdgeInsets.all(8),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [ArabicNumberTextInputFormatter()],
                    onChanged: (value) {
                      line.cashCredit = double.tryParse(value) ?? 0.0;
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: line.goldDebitController,
                    decoration: InputDecoration(
                      labelText: 'مدين ذهب (جم)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: EdgeInsets.all(8),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [ArabicNumberTextInputFormatter()],
                    onChanged: (value) {
                      line.goldDebit = double.tryParse(value) ?? 0.0;
                    },
                  ),
                ),
                SizedBox(width: 8),
                Expanded(
                  child: TextFormField(
                    controller: line.goldCreditController,
                    decoration: InputDecoration(
                      labelText: 'دائن ذهب (جم)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      contentPadding: EdgeInsets.all(8),
                    ),
                    keyboardType: TextInputType.number,
                    inputFormatters: [ArabicNumberTextInputFormatter()],
                    onChanged: (value) {
                      line.goldCredit = double.tryParse(value) ?? 0.0;
                    },
                  ),
                ),
              ],
            ),
            SizedBox(height: 8),
            TextFormField(
              controller: line.descriptionController,
              decoration: InputDecoration(
                labelText: 'البيان',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.all(8),
              ),
              onChanged: (value) {
                line.description = value;
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      width: double.infinity,
      height: 50,
      child: ElevatedButton.icon(
        onPressed: _isLoading ? null : _saveTemplate,
        icon: _isLoading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.save),
        label: Text(
          _isLoading ? 'جاري الحفظ...' : 'حفظ القالب',
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: Theme.of(context).colorScheme.onPrimary,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.primary,
          foregroundColor: Theme.of(context).colorScheme.onPrimary,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );
  }
}

/// كلاس لإدارة سطر القالب
class RecurringTemplateLine {
  int? accountId;
  double cashDebit = 0.0;
  double cashCredit = 0.0;
  double goldDebit = 0.0;
  double goldCredit = 0.0;
  String description = '';

  late TextEditingController cashDebitController;
  late TextEditingController cashCreditController;
  late TextEditingController goldDebitController;
  late TextEditingController goldCreditController;
  late TextEditingController descriptionController;

  RecurringTemplateLine({
    this.accountId,
    this.cashDebit = 0.0,
    this.cashCredit = 0.0,
    this.goldDebit = 0.0,
    this.goldCredit = 0.0,
    this.description = '',
  }) {
    cashDebitController = TextEditingController(text: cashDebit.toString());
    cashCreditController = TextEditingController(text: cashCredit.toString());
    goldDebitController = TextEditingController(text: goldDebit.toString());
    goldCreditController = TextEditingController(text: goldCredit.toString());
    descriptionController = TextEditingController(text: description);
  }

  factory RecurringTemplateLine.fromMap(Map<String, dynamic> map) {
    return RecurringTemplateLine(
      accountId: map['account_id'],
      cashDebit: (map['cash_debit'] ?? 0.0).toDouble(),
      cashCredit: (map['cash_credit'] ?? 0.0).toDouble(),
      goldDebit: (map['debit_21k'] ?? 0.0).toDouble(),
      goldCredit: (map['credit_21k'] ?? 0.0).toDouble(),
      description: map['description'] ?? '',
    );
  }

  void dispose() {
    cashDebitController.dispose();
    cashCreditController.dispose();
    goldDebitController.dispose();
    goldCreditController.dispose();
    descriptionController.dispose();
  }
}
