import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/category_model.dart';
import '../theme/app_theme.dart';
import '../services/data_sync_bus.dart';
import '../utils.dart';
import '../theme/app_semantic_colors.dart';

/// The theme's colours (ADR-038): the scheme and the semantic tones.
ColorScheme _cs(BuildContext context) => Theme.of(context).colorScheme;
AppSemanticColors _tn(BuildContext context) => AppSemanticColors.of(context);

/// 🚀 شاشة الإضافة السريعة للأصناف
/// مصممة خصيصاً لإضافة قطع ذهبية متعددة بسرعة
class QuickAddItemsScreen extends StatefulWidget {
  final ApiService api;
  final Map<String, dynamic>? templateItem; // للاستنساخ
  final bool embedded; // 👇 وضع مدمج داخل شاشة أخرى؟
  final VoidCallback? onSuccess; // 🔔 استدعاء عند النجاح في الوضع المدمج

  const QuickAddItemsScreen({
    super.key,
    required this.api,
    this.templateItem,
    this.embedded = false,
    this.onSuccess,
  });

  @override
  State<QuickAddItemsScreen> createState() => _QuickAddItemsScreenState();
}

class _QuickAddItemsScreenState extends State<QuickAddItemsScreen> {
  final _formKey = GlobalKey<FormState>();

  // البيانات المشتركة
  final TextEditingController _baseNameController = TextEditingController();
  final TextEditingController _wagePerGramController = TextEditingController();
  final TextEditingController _bulkWeightsController = TextEditingController();
  String _selectedKarat = '21';
  int? _selectedCategoryId;

  /// The categories of the chosen karat only -- the server refuses another.
  List<Category> get _categoriesOfKarat => categories
      .where((c) => (c.karat ?? '').toString().trim() == _selectedKarat)
      .toList();
  bool _hasStones = false;

  // قائمة الأوزان
  List<PieceData> pieces = [PieceData()];

  // التصنيفات
  List<Category> categories = [];
  bool categoriesLoading = false;
  bool saving = false;

  void _resetAfterSave() {
    for (final piece in pieces) {
      piece.dispose();
    }
    setState(() {
      _baseNameController.clear();
      _wagePerGramController.clear();
      _bulkWeightsController.clear();
      _selectedKarat = '21';
      _selectedCategoryId = null;
      _hasStones = false;
      pieces = [PieceData()];
    });
  }

  @override
  void initState() {
    super.initState();
    _loadCategories();

    // إذا كان هناك قطعة للاستنساخ، نملأ البيانات
    if (widget.templateItem != null) {
      _fillFromTemplate(widget.templateItem!);
    }
  }

  void _fillFromTemplate(Map<String, dynamic> item) {
    _baseNameController.text = item['name'] ?? '';
    _selectedKarat = item['karat']?.toString() ?? '21';
    _selectedCategoryId = item['category_id'];
    _hasStones = item['has_stones'] == true;

    // حساب الأجرة للجرام
    final weight = double.tryParse(item['weight']?.toString() ?? '0') ?? 0;
    final wage = double.tryParse(item['wage']?.toString() ?? '0') ?? 0;
    if (weight > 0) {
      final wagePerGram = wage / weight;
      _wagePerGramController.text = wagePerGram.toStringAsFixed(2);
    }
  }

  Future<void> _loadCategories() async {
    setState(() => categoriesLoading = true);
    try {
      final data = await widget.api.getCategories();
      setState(() {
        categories = data.map((json) => Category.fromJson(json)).toList();
        categoriesLoading = false;
      });
    } catch (e) {
      setState(() => categoriesLoading = false);
    }
  }

  void _addPiece() {
    setState(() {
      pieces.add(PieceData());
    });
  }

  void _addPieces(int count) {
    setState(() {
      for (var i = 0; i < count; i++) {
        pieces.add(PieceData());
      }
    });
  }

  void _clonePiece(int index) {
    final source = pieces[index];
    final newPiece = PieceData();
    newPiece.weightController.text = source.weightController.text;
    newPiece.nameController.text = source.nameController.text;
    newPiece.descriptionController.text = source.descriptionController.text;
    newPiece.stonesWeightController.text = source.stonesWeightController.text;
    newPiece.stonesValueController.text = source.stonesValueController.text;

    setState(() {
      pieces.insert(index + 1, newPiece);
    });
  }

  void _importBulkWeights() {
    final text = _bulkWeightsController.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ الرجاء لصق الأوزان أولاً'),
          backgroundColor: _tn(context).warning.fg,
        ),
      );
      return;
    }

    final matches = RegExp(r'[-+]?\d*\.?\d+')
        .allMatches(text)
        .map((m) => double.tryParse(m.group(0) ?? ''))
        .where((value) => value != null && value > 0)
        .map((value) => value!)
        .toList();

    if (matches.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ لم يتم العثور على أوزان صالحة'),
          backgroundColor: _tn(context).warning.fg,
        ),
      );
      return;
    }

    setState(() {
      var pieceIndex = 0;
      for (final weight in matches) {
        PieceData target;
        if (pieceIndex < pieces.length) {
          target = pieces[pieceIndex];
        } else {
          target = PieceData();
          pieces.add(target);
        }
        target.weightController.text = weight.toStringAsFixed(3);
        pieceIndex++;
      }
    });

    _bulkWeightsController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('✅ تم استيراد ${matches.length} وزن بنجاح'),
        backgroundColor: _tn(context).ready.fg,
      ),
    );
  }

  void _removePiece(int index) {
    if (pieces.length > 1) {
      setState(() {
        pieces.removeAt(index);
      });
    }
  }

  Future<void> _saveItems() async {
    if (!_formKey.currentState!.validate()) return;

    // التحقق من وجود قطعة واحدة على الأقل بوزن صحيح
    final validPieces = pieces
        .where(
          (p) =>
              p.weightController.text.isNotEmpty &&
              (double.tryParse(p.weightController.text) ?? 0) > 0,
        )
        .toList();

    if (validPieces.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('⚠️ يرجى إدخال وزن صحيح لقطعة واحدة على الأقل'),
          backgroundColor: _tn(context).warning.fg,
        ),
      );
      return;
    }

    setState(() => saving = true);

    try {
      final wagePerGram = double.tryParse(_wagePerGramController.text) ?? 0;

      final requestBody = {
        'base_name': _baseNameController.text.trim(),
        'category_id': _selectedCategoryId,
        'karat': _selectedKarat,
        'wage_per_gram': wagePerGram,
        'has_stones': _hasStones,
        'pieces': validPieces.map((p) {
          final weight = double.parse(p.weightController.text);
          return {
            'weight': weight,
            'description': p.descriptionController.text.trim(),
            'name': p.nameController.text.trim().isEmpty
                ? null
                : p.nameController.text.trim(),
            if (_hasStones) ...{
              'stones_weight':
                  double.tryParse(p.stonesWeightController.text) ?? 0,
              'stones_value':
                  double.tryParse(p.stonesValueController.text) ?? 0,
            },
          };
        }).toList(),
      };

      final result = await widget.api.quickAddItems(requestBody);
      DataSyncBus.notifyItemsChanged();

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(result['message'] ?? '✅ تم إضافة الأصناف بنجاح'),
          backgroundColor: _tn(context).ready.fg,
        ),
      );

      if (widget.embedded) {
        widget.onSuccess?.call();
      } else {
        _resetAfterSave();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('❌ خطأ: ${e.toString()}'),
          backgroundColor: _cs(context).error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => saving = false);
      }
    }
  }

  @override
  void dispose() {
    _baseNameController.dispose();
    _wagePerGramController.dispose();
    _bulkWeightsController.dispose();
    for (var piece in pieces) {
      piece.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildFormContent(context);

    if (widget.embedded) {
      return content;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('🚀 إضافة سريعة للأصناف'),
        actions: [
          if (saving)
            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.check),
              onPressed: _saveItems,
              tooltip: 'حفظ الكل',
            ),
        ],
      ),
      body: content,
    );
  }

  Widget _buildFormContent(BuildContext context) {
    final theme = Theme.of(context);

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (widget.embedded)
            Card(
              margin: const EdgeInsets.only(bottom: 16),
              color: _cs(context).primary.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '⚡ وضع الإضافة السريعة',
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: _cs(context).primary,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'الصق الأوزان أو أضِف عدة بطاقات بنفس المعلومات المشتركة، ثم احفظ الكل دفعة واحدة.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton.icon(
                      onPressed: saving ? null : _saveItems,
                      icon: saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.done_all),
                      label: Text(saving ? 'جارٍ الحفظ' : 'حفظ الكل'),
                    ),
                  ],
                ),
              ),
            ),

          // 📝 البيانات المشتركة
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '📝 البيانات المشتركة',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _cs(context).primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // الاسم الأساسي
                  TextFormField(
                    controller: _baseNameController,
                    decoration: const InputDecoration(
                      labelText: '* الاسم الأساسي',
                      hintText: 'مثال: بنجرة، خاتم، أسورة',
                      prefixIcon: Icon(Icons.label_outline),
                    ),
                    validator: (v) =>
                        v == null || v.trim().isEmpty ? 'مطلوب' : null,
                  ),
                  const SizedBox(height: 12),

                  // العيار
                  DropdownButtonFormField<String>(
                    // ignore: deprecated_member_use
                    value: _selectedKarat,
                    decoration: const InputDecoration(
                      labelText: 'العيار',
                      prefixIcon: Icon(Icons.stars),
                    ),
                    items: ['18', '21', '22', '24'].map((k) {
                      return DropdownMenuItem(value: k, child: Text('عيار $k'));
                    }).toList(),
                    // A category of another karat is no longer offered -- its
                    // karat is the pieces' (ADR-045 B: one karat never mistaken
                    // for another in manual entry).
                    onChanged: (v) => setState(() {
                      _selectedKarat = v!;
                      if (!_categoriesOfKarat.any((c) => c.id == _selectedCategoryId)) {
                        _selectedCategoryId = null;
                      }
                    }),
                  ),
                  const SizedBox(height: 12),

                  // التصنيف
                  if (categoriesLoading)
                    const LinearProgressIndicator()
                  else
                    DropdownButtonFormField<int>(
                      // ignore: deprecated_member_use
                      value: _selectedCategoryId,
                      decoration: const InputDecoration(
                        labelText: 'التصنيف (اختياري)',
                        prefixIcon: Icon(Icons.category),
                      ),
                      items: _categoriesOfKarat.map((cat) {
                        return DropdownMenuItem(
                          value: cat.id,
                          child: Text(cat.name),
                        );
                      }).toList(),
                      onChanged: (v) => setState(() => _selectedCategoryId = v),
                    ),
                  const SizedBox(height: 12),

                  // الأجرة للجرام
                  TextFormField(
                    controller: _wagePerGramController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [NormalizeNumberFormatter()],
                    decoration: const InputDecoration(
                      labelText: '* الأجرة للجرام',
                      hintText: '0.00',
                      prefixIcon: Icon(Icons.attach_money),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'مطلوب';
                      if (double.tryParse(v) == null) return 'رقم غير صحيح';
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),

                  // أحجار؟
                  SwitchListTile(
                    title: const Text('يحتوي على أحجار'),
                    value: _hasStones,
                    onChanged: (v) => setState(() => _hasStones = v),
                    contentPadding: EdgeInsets.zero,
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // ⚡ طرق إدخال أسرع
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚡ طرق إدخال أسرع',
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: _cs(context).primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'يمكنك لصق أوزان من Excel أو من ميزان رقمي مباشرة، أو إضافة عدة بطاقات دفعة واحدة.',
                    style: theme.textTheme.bodySmall,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _bulkWeightsController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'الصق الأوزان هنا',
                      hintText:
                          'مثال: 4.123\n4.215\n4.198 أو 4.123, 4.215, 4.198',
                      prefixIcon: Icon(Icons.paste),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _importBulkWeights,
                        icon: const Icon(Icons.download),
                        label: const Text('استيراد الأوزان'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _addPieces(5),
                        icon: const Icon(Icons.queue),
                        label: const Text('إضافة 5 قطع'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _addPieces(10),
                        icon: const Icon(Icons.library_add),
                        label: const Text('إضافة 10 قطع'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // 💎 القطع
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '💎 القطع (${pieces.length})',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: _cs(context).primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_circle),
                onPressed: _addPiece,
                tooltip: 'إضافة قطعة',
              ),
            ],
          ),
          const SizedBox(height: 8),

          ...pieces.asMap().entries.map((entry) {
            final index = entry.key;
            final piece = entry.value;

            return Card(
              margin: const EdgeInsets.only(bottom: 12),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Chip(
                          label: Text('قطعة ${index + 1}'),
                          backgroundColor: _cs(context).primaryContainer,
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          icon: const Icon(Icons.copy_all),
                          tooltip: 'نسخ هذه القطعة كقطعة جديدة',
                          onPressed: () => _clonePiece(index),
                        ),
                        const Spacer(),
                        if (pieces.length > 1)
                          IconButton(
                            icon: const Icon(Icons.delete_outline),
                            iconSize: 20,
                            color: _cs(context).error,
                            onPressed: () => _removePiece(index),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // الوزن (إجباري)
                    TextFormField(
                      controller: piece.weightController,
                      keyboardType: TextInputType.number,
                      inputFormatters: [NormalizeNumberFormatter()],
                      decoration: const InputDecoration(
                        labelText: '* الوزن (جرام)',
                        hintText: '0.000',
                        prefixIcon: Icon(Icons.scale),
                        isDense: true,
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return 'مطلوب';
                        final weight = double.tryParse(v);
                        if (weight == null || weight <= 0) {
                          return 'الوزن يجب أن يكون أكبر من صفر';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 8),

                    // اسم مخصص (اختياري)
                    TextFormField(
                      controller: piece.nameController,
                      decoration: const InputDecoration(
                        labelText: 'اسم مخصص (اختياري)',
                        hintText: 'سيتم توليد الاسم تلقائياً',
                        prefixIcon: Icon(Icons.edit),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),

                    // ملاحظات
                    TextFormField(
                      controller: piece.descriptionController,
                      decoration: const InputDecoration(
                        labelText: 'ملاحظات',
                        hintText: 'مثال: قطعة كبيرة، لون فاتح',
                        prefixIcon: Icon(Icons.note),
                        isDense: true,
                      ),
                      maxLines: 2,
                    ),

                    // حقول الأحجار
                    if (_hasStones) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: piece.stonesWeightController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [NormalizeNumberFormatter()],
                              decoration: const InputDecoration(
                                labelText: 'وزن الأحجار (جرام)',
                                hintText: '0.000',
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextFormField(
                              controller: piece.stonesValueController,
                              keyboardType: TextInputType.number,
                              inputFormatters: [NormalizeNumberFormatter()],
                              decoration: const InputDecoration(
                                labelText: 'قيمة الأحجار',
                                hintText: '0.00',
                                isDense: true,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),

          const SizedBox(height: 16),

          // زر الحفظ
          ElevatedButton.icon(
            onPressed: saving ? null : _saveItems,
            icon: saving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle),
            label: Text(saving ? 'جاري الحفظ...' : 'حفظ الكل'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 16),
              backgroundColor: _cs(context).primary,
            ),
          ),
        ],
      ),
    );
  }
}

/// بيانات قطعة واحدة
class PieceData {
  final TextEditingController weightController = TextEditingController();
  final TextEditingController nameController = TextEditingController();
  final TextEditingController descriptionController = TextEditingController();
  final TextEditingController stonesWeightController = TextEditingController();
  final TextEditingController stonesValueController = TextEditingController();

  void dispose() {
    weightController.dispose();
    nameController.dispose();
    descriptionController.dispose();
    stonesWeightController.dispose();
    stonesValueController.dispose();
  }
}
