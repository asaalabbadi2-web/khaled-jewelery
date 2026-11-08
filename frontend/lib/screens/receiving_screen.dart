import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../models/category_model.dart';
import '../providers/settings_provider.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/confirm_financial_action.dart';
import '../widgets/inline_number_cell.dart';
import '../widgets/party_picker_dialog.dart';
import '../widgets/searchable_picker_field.dart';

/// Receiving a supplier's gold before his invoice (ADR-087 R2).
///
/// The owner, 8 Nov 2026: receiving comes first, its own screen. A line is a
/// category of its karat with two weights -- the supplier's, from his paper,
/// and the one received on the scale; their difference is said beside it.
/// The tolerance is the server's: above it the server refuses, and the
/// screen asks the owner's or the manager's reason and sends it again. One
/// key for each document, kept across its retries: one document however
/// often it is sent. Saved, its gold is in the books; its invoice is
/// completed later, from «استلامات بلا فاتورة».
class ReceivingScreen extends StatefulWidget {
  const ReceivingScreen({super.key, this.api});
  final ApiService? api;

  @override
  State<ReceivingScreen> createState() => _ReceivingScreenState();
}

class _ReceiptLine {
  _ReceiptLine({
    required this.category,
    required this.karat,
    required this.supplierWeight,
    required this.weight,
  });
  final Category category;
  final int karat;
  final double supplierWeight;
  final double weight;

  double get difference => weight - supplierWeight;
}

class _ReceivingScreenState extends State<ReceivingScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  List<Map<String, dynamic>> _suppliers = [];
  List<Category> _categories = [];
  Object? _error;
  bool _loading = true;
  bool _saving = false;

  int? _supplierId;
  final _paperNumber = TextEditingController();
  final _supplierWeight = TextEditingController();
  final _weight = TextEditingController();
  final _weightFocus = FocusNode();
  late int _karat = context.read<SettingsProvider>().mainKarat;
  int? _categoryId;
  final List<_ReceiptLine> _lines = [];
  String? _lineError;

  /// The document's key: made at its first save attempt, kept for its
  /// retries, new after it is saved (ADR-087 §1أ ٤).
  String? _requestKey;

  static const _karats = [18, 21, 22, 24];

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _paperNumber.dispose();
    _supplierWeight.dispose();
    _weight.dispose();
    _weightFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final suppliers = await _api.getSuppliers();
      final categories = await _api.getCategories();
      if (!mounted) return;
      setState(() {
        _suppliers = suppliers.whereType<Map<String, dynamic>>().toList();
        _categories = categories
            .whereType<Map<String, dynamic>>()
            .map(Category.fromJson)
            .where((c) => c.isActive && !c.isScrap && c.id != null)
            .toList();
        _loading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  List<Category> get _ofKarat => _categories
      .where((c) => double.tryParse(c.karat ?? '') == _karat.toDouble())
      .toList();

  String? get _supplierName => _suppliers
      .where((s) => s['id'] == _supplierId)
      .map((s) => s['name']?.toString())
      .firstOrNull;

  Future<void> _pickSupplier() async {
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => PartyPickerDialog(
        title: 'اختيار مورد',
        items: _suppliers,
        selectedId: _supplierId,
        emptyText: 'لا يوجد مورد مطابق',
      ),
    );
    if (picked != null && mounted) {
      setState(() => _supplierId = picked['id'] as int?);
    }
  }

  void _addLine() {
    final category = _ofKarat.where((c) => c.id == _categoryId).firstOrNull;
    final weight = readTypedNumber(_weight.text) ?? 0;
    final paper = readTypedNumber(_supplierWeight.text);
    if (category == null) {
      setState(() => _lineError = 'اختر التصنيف');
      return;
    }
    if (weight <= 0) {
      setState(() => _lineError = 'أدخل الوزن المستلم');
      _weightFocus.requestFocus();
      return;
    }
    setState(() {
      _lines.add(
        _ReceiptLine(
          category: category,
          karat: _karat,
          supplierWeight: paper == null || paper <= 0 ? weight : paper,
          weight: weight,
        ),
      );
      _lineError = null;
      _supplierWeight.clear();
      _weight.clear();
    });
  }

  Map<String, dynamic> _body({String? approvalReason}) => {
    'supplier_id': _supplierId,
    'request_key': _requestKey,
    if (_paperNumber.text.trim().isNotEmpty)
      'supplier_invoice_number': _paperNumber.text.trim(),
    'lines': [
      for (final l in _lines)
        {
          'category_id': l.category.id,
          'karat': l.karat,
          'weight': l.weight,
          'supplier_weight': l.supplierWeight,
        },
    ],
    if (approvalReason != null)
      'difference_approval': {'reason': approvalReason},
  };

  Future<void> _save() async {
    if (_supplierId == null || _lines.isEmpty || _saving) return;
    final ok = await confirmFinancialAction(
      context,
      title: 'حفظ الاستلام؟',
      effect: 'يُرحَّل ذهب الاستلام الآن: يدخل المخزون، ويُقيَّد للمورد وزن ورقته. '
          'وتُستكمل فاتورته لاحقًا من «استلامات بلا فاتورة».',
      confirmLabel: 'حفظ الاستلام',
      destructive: false,
      facts: [
        ('المورد', _supplierName ?? '-'),
        ('الأسطر', '${_lines.length}'),
      ],
    );
    if (ok == null || !mounted) return;
    _requestKey ??=
        '${Random.secure().nextInt(1 << 32)}-${Random.secure().nextInt(1 << 32)}';
    await _send();
  }

  Future<void> _send({String? approvalReason}) async {
    setState(() => _saving = true);
    try {
      final saved = await _api.receivePurchase(
        _body(approvalReason: approvalReason),
      );
      if (!mounted) return;
      final invoice = saved['invoice'] as Map<String, dynamic>? ?? const {};
      AppFeedback.success(
        context,
        'حُفظ الاستلام ${invoice['invoice_number'] ?? ''}: تُستكمل فاتورته من «استلامات بلا فاتورة»',
      );
      setState(() {
        _lines.clear();
        _paperNumber.clear();
        _requestKey = null;
        _saving = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      if (e.code == 'receipt_difference_over_tolerance') {
        final reason = await confirmFinancialAction(
          context,
          title: 'فرق الوزن فوق الحدّ',
          effect: '${e.message}\nيعتمده المالك أو المدير، بسبب.',
          confirmLabel: 'اعتماد الفرق',
          reasonLabel: 'سبب الفرق',
          destructive: false,
        );
        if (reason != null && reason.trim().isNotEmpty && mounted) {
          await _send(approvalReason: reason.trim());
        }
        return;
      }
      AppFeedback.error(context, e);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('استلام ذهب من مورد')),
        body: _loading
            ? const AppLoadingView()
            : _error != null
            ? AppErrorView(
                title: 'تعذّر تحميل الموردين والتصنيفات',
                error: _error,
                onRetry: _load,
              )
            : _content(context),
        bottomNavigationBar: _loading || _error != null
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: FilledButton.icon(
                    key: const Key('receiving-save'),
                    onPressed:
                        _supplierId == null || _lines.isEmpty || _saving
                        ? null
                        : _save,
                    icon: const Icon(Icons.inventory_2_outlined),
                    label: Text(
                      _supplierId == null
                          ? 'اختر المورد'
                          : _lines.isEmpty
                          ? 'أضف أسطر الاستلام'
                          : 'حفظ الاستلام',
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _content(BuildContext context) {
    final theme = Theme.of(context);
    final ofKarat = _ofKarat;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SearchablePickerField(
          labelText: 'المورد',
          valueText: _supplierName,
          hintText: 'اضغط للبحث والاختيار',
          prefixIcon: Icons.store_mall_directory,
          enabled: _suppliers.isNotEmpty,
          onTap: _pickSupplier,
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('receiving-paper-number'),
          controller: _paperNumber,
          textDirection: TextDirection.ltr,
          decoration: const InputDecoration(
            labelText: 'رقم ورقة المورد (اختياري)',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.receipt_long_outlined),
          ),
        ),
        const SizedBox(height: 20),
        Text('أسطر الاستلام', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SegmentedButton<int>(
              segments: [
                for (final k in _karats)
                  ButtonSegment(value: k, label: Text('$k')),
              ],
              selected: {_karat},
              showSelectedIcon: false,
              onSelectionChanged: (s) => setState(() {
                _karat = s.first;
                _categoryId = null;
              }),
            ),
            SizedBox(
              width: 220,
              child: DropdownButtonFormField<int>(
                key: const Key('receiving-category'),
                initialValue: ofKarat.any((c) => c.id == _categoryId)
                    ? _categoryId
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'التصنيف',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                hint: Text(
                  ofKarat.isEmpty ? 'لا تصنيف لعيار $_karat' : 'اختر التصنيف',
                ),
                items: [
                  for (final c in ofKarat)
                    DropdownMenuItem(value: c.id, child: Text(c.name)),
                ],
                onChanged: (v) => setState(() => _categoryId = v),
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                key: const Key('receiving-supplier-weight'),
                controller: _supplierWeight,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: typedNumberFormatters(),
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'وزن المورد',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _weightFocus.requestFocus(),
              ),
            ),
            SizedBox(
              width: 140,
              child: TextField(
                key: const Key('receiving-weight'),
                controller: _weight,
                focusNode: _weightFocus,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: typedNumberFormatters(),
                textDirection: TextDirection.ltr,
                decoration: const InputDecoration(
                  labelText: 'الوزن المستلم',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addLine(),
              ),
            ),
            FilledButton.icon(
              key: const Key('receiving-add'),
              onPressed: _addLine,
              icon: const Icon(Icons.keyboard_return),
              label: const Text('إضافة'),
            ),
          ],
        ),
        if (_lineError != null) ...[
          const SizedBox(height: 4),
          Text(
            _lineError!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (_lines.isEmpty)
          const AppEmptyView(
            title: 'لا أسطر بعد',
            hint: 'اختر التصنيف، واكتب وزن المورد والوزن المستلم',
            icon: Icons.scale_outlined,
          )
        else
          for (var i = 0; i < _lines.length; i++) _lineTile(context, i),
      ],
    );
  }

  Widget _lineTile(BuildContext context, int i) {
    final theme = Theme.of(context);
    final l = _lines[i];
    final differs = l.difference.abs() >= 0.005;
    return Card(
      child: ListTile(
        title: Text('${l.category.name} — عيار ${l.karat}'),
        subtitle: Text(
          'وزن المورد ${formatGrams(l.supplierWeight, decimals: 2)} جم · '
          'المستلم ${formatGrams(l.weight, decimals: 2)} جم',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (differs)
              Text(
                '${l.difference > 0 ? '+' : ''}${formatGrams(l.difference, decimals: 2)}',
                textDirection: TextDirection.ltr,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            IconButton(
              tooltip: 'حذف السطر',
              icon: const Icon(Icons.delete_outline),
              onPressed: () => setState(() => _lines.removeAt(i)),
            ),
          ],
        ),
      ),
    );
  }
}
