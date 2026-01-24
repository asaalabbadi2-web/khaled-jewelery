import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/category_model.dart';
import '../models/safe_box_model.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';

class CategoryOpeningBalanceScreen extends StatefulWidget {
  final ApiService api;
  final List<Category>? initialCategories;

  const CategoryOpeningBalanceScreen({
    super.key,
    required this.api,
    this.initialCategories,
  });

  @override
  State<CategoryOpeningBalanceScreen> createState() =>
      _CategoryOpeningBalanceScreenState();
}

class _AdjustmentLine {
  Category? category;
  int? karat;
  final TextEditingController weightController = TextEditingController();

  void dispose() {
    weightController.dispose();
  }
}

class _CategoryOpeningBalanceScreenState
    extends State<CategoryOpeningBalanceScreen> {
  bool _loading = true;
  bool _submitting = false;

  List<Category> _categories = [];
  List<SafeBoxModel> _goldSafes = [];

  SafeBoxModel? _selectedSafe;
  DateTime _selectedDate = DateTime.now();
  final TextEditingController _noteController = TextEditingController();

  final List<_AdjustmentLine> _lines = [];

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    for (final line in _lines) {
      line.dispose();
    }
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() => _loading = true);

    try {
      final categories = widget.initialCategories;
      if (categories != null && categories.isNotEmpty) {
        _categories = List<Category>.from(categories);
      } else {
        final raw = await widget.api.getCategories();
        _categories = raw.map((j) => Category.fromJson(j)).toList();
      }

      _goldSafes = await widget.api.getSafeBoxes(
        safeType: 'gold',
        isActive: true,
        includeAccount: false,
        includeBalance: false,
      );

      _goldSafes.sort((a, b) => a.name.compareTo(b.name));

      if (_goldSafes.isNotEmpty) {
        _selectedSafe = _goldSafes.first;
      }

      if (_lines.isEmpty) {
        _addLine();
      }

      setState(() => _loading = false);
    } catch (e) {
      setState(() => _loading = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في تحميل البيانات: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    }
  }

  void _addLine() {
    setState(() {
      final line = _AdjustmentLine();
      _lines.add(line);
    });
  }

  void _removeLine(int index) {
    setState(() {
      final removed = _lines.removeAt(index);
      removed.dispose();
      if (_lines.isEmpty) {
        _addLine();
      }
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2100, 12, 31),
    );

    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  int? _parseDefaultKaratFromCategory(Category category) {
    final raw = category.karat;
    if (raw == null || raw.trim().isEmpty) return null;
    return int.tryParse(raw.trim());
  }

  Future<void> _submit() async {
    if (_submitting) return;

    final safeId = _selectedSafe?.id;
    final validLines = <Map<String, dynamic>>[];

    for (final line in _lines) {
      final category = line.category;
      final karat = line.karat;
      final weight = double.tryParse(line.weightController.text.trim());

      if (category?.id == null || karat == null || weight == null) {
        continue;
      }
      if (weight <= 0) continue;

      final payload = <String, dynamic>{
        'category_id': category!.id,
        'karat': karat,
        'weight_grams': weight,
        'line_label': category.name,
      };
      if (safeId != null) {
        payload['safe_box_id'] = safeId;
      }
      validLines.add(payload);
    }

    if (validLines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('أضف سطر واحد صالح على الأقل (تصنيف + عيار + وزن).'),
          backgroundColor: AppColors.error,
        ),
      );
      return;
    }

    setState(() => _submitting = true);
    try {
      final auth = context.read<AuthProvider>();
      await widget.api.createCategoryWeightAdjustments(
        goldType: 'new',
        lines: validLines,
        createdBy: auth.username,
        note: _noteController.text.trim(),
        date: _selectedDate,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✅ تم تسجيل الرصيد الافتتاحي للتصنيفات بنجاح'),
          backgroundColor: AppColors.success,
        ),
      );
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('فشل الحفظ: $e'),
          backgroundColor: AppColors.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final formattedDate = DateFormat('yyyy-MM-dd').format(_selectedDate);

    return Scaffold(
      appBar: AppBar(
        title: const Text('رصيد افتتاحي للتصنيفات'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.diamond, color: AppColors.primaryGold),
                                const SizedBox(width: 8),
                                const Expanded(
                                  child: Text(
                                    'هذا الإدخال مخصص لذهب جديد (71300) فقط',
                                    style: TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            DropdownButtonFormField<int?>(
                              value: _selectedSafe?.id,
                              decoration: const InputDecoration(
                                labelText: 'الخزنة الذهبية (اختياري)',
                                border: OutlineInputBorder(),
                              ),
                              items: [
                                const DropdownMenuItem<int?>(
                                  value: null,
                                  child: Text('بدون تحديد خزنة'),
                                ),
                                ..._goldSafes.map(
                                  (s) => DropdownMenuItem<int?>(
                                    value: s.id,
                                    child: Text(s.name),
                                  ),
                                ),
                              ],
                              onChanged: (value) {
                                setState(() {
                                  _selectedSafe = _goldSafes
                                      .where((s) => s.id == value)
                                      .cast<SafeBoxModel?>()
                                      .firstOrNull;
                                });
                              },
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'تاريخ التسجيل',
                                      border: OutlineInputBorder(),
                                    ),
                                    child: Text(formattedDate),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                ElevatedButton.icon(
                                  onPressed: _pickDate,
                                  icon: const Icon(Icons.date_range),
                                  label: const Text('اختيار'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              controller: _noteController,
                              decoration: const InputDecoration(
                                labelText: 'ملاحظة (اختياري)',
                                border: OutlineInputBorder(),
                              ),
                              maxLines: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Text(
                          'الأسطر',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const Spacer(),
                        OutlinedButton.icon(
                          onPressed: _addLine,
                          icon: const Icon(Icons.add),
                          label: const Text('إضافة سطر'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ...List.generate(_lines.length, (index) {
                      final line = _lines[index];

                      return Card(
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<int?>(
                                      value: line.category?.id,
                                      decoration: const InputDecoration(
                                        labelText: 'التصنيف',
                                        border: OutlineInputBorder(),
                                      ),
                                      items: _categories
                                          .where((c) => c.id != null)
                                          .map(
                                            (c) => DropdownMenuItem<int?>(
                                              value: c.id,
                                              child: Text(c.name),
                                            ),
                                          )
                                          .toList(growable: false),
                                      onChanged: (value) {
                                        final category = _categories
                                            .where((c) => c.id == value)
                                            .cast<Category?>()
                                            .firstOrNull;

                                        setState(() {
                                          line.category = category;
                                          final defaultKarat =
                                              category != null
                                                  ? _parseDefaultKaratFromCategory(
                                                    category,
                                                  )
                                                  : null;
                                          if (defaultKarat != null) {
                                            line.karat = defaultKarat;
                                          }
                                        });
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  SizedBox(
                                    width: 140,
                                    child: DropdownButtonFormField<int>(
                                      value: line.karat,
                                      decoration: const InputDecoration(
                                        labelText: 'العيار',
                                        border: OutlineInputBorder(),
                                      ),
                                      items: const [
                                        DropdownMenuItem(
                                          value: 18,
                                          child: Text('18'),
                                        ),
                                        DropdownMenuItem(
                                          value: 21,
                                          child: Text('21'),
                                        ),
                                        DropdownMenuItem(
                                          value: 22,
                                          child: Text('22'),
                                        ),
                                        DropdownMenuItem(
                                          value: 24,
                                          child: Text('24'),
                                        ),
                                      ],
                                      onChanged: (value) {
                                        setState(() => line.karat = value);
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: line.weightController,
                                      decoration: const InputDecoration(
                                        labelText: 'الوزن بالجرام',
                                        border: OutlineInputBorder(),
                                        hintText: 'مثال: 12.345',
                                      ),
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  IconButton(
                                    onPressed: () => _removeLine(index),
                                    icon: Icon(
                                      Icons.delete,
                                      color: AppColors.error,
                                    ),
                                    tooltip: 'حذف السطر',
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _submitting ? null : _submit,
                        icon: const Icon(Icons.save),
                        label: Text(_submitting ? 'جاري الحفظ...' : 'حفظ'),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.all(16),
                        ),
                      ),
                    ),
                  ],
                ),
                if (_submitting)
                  Positioned.fill(
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.15),
                      child: const Center(child: CircularProgressIndicator()),
                    ),
                  ),
              ],
            ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
