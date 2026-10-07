import 'package:flutter/material.dart';

import 'inline_number_cell.dart';

/// One category line of a sale, as the entry row hands it back.
class SalesCategoryEntry {
  final Map<String, dynamic> category;
  final int karat;
  final double weight;
  final double wage;
  final int count;

  /// The line's total with VAT when the seller fixed it, else null.
  final double? amount;

  const SalesCategoryEntry({
    required this.category,
    required this.karat,
    required this.weight,
    required this.wage,
    required this.count,
    this.amount,
  });
}

const _sellableKarats = [18, 21, 22, 24];

int? _categoryKarat(Map<String, dynamic> category) {
  final k = int.tryParse('${category['karat'] ?? ''}');
  return _sellableKarats.contains(k) ? k : null;
}

double? _categoryWage(Map<String, dynamic> category) {
  final raw = category['default_wage'];
  final w = raw is num ? raw.toDouble() : double.tryParse('${raw ?? ''}');
  return (w != null && w > 0) ? w : null;
}

/// A sale's lines typed in one row (SALES-UX-3): the category, its weight,
/// Enter. The category's karat and wage hold when it has them; the weight is
/// the line's, the count a note. 2,549 of the 2,576 lines on the 6 Oct copy
/// are category lines, and a dialog opened for each.
class SalesCategoryEntryRow extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final int mainKarat;
  final ValueChanged<SalesCategoryEntry> onAdd;

  const SalesCategoryEntryRow({
    super.key,
    required this.categories,
    required this.mainKarat,
    required this.onAdd,
  });

  @override
  State<SalesCategoryEntryRow> createState() => _SalesCategoryEntryRowState();
}

class _SalesCategoryEntryRowState extends State<SalesCategoryEntryRow> {
  final _weight = TextEditingController();
  final _wage = TextEditingController(text: '0');
  final _count = TextEditingController(text: '1');
  final _amount = TextEditingController();
  final _categoryFocus = FocusNode();
  final _weightFocus = FocusNode();
  final _wageFocus = FocusNode();
  TextEditingController? _categoryText;

  Map<String, dynamic>? _category;
  late int _karat = widget.mainKarat;
  String? _error;

  int? get _lockedKarat =>
      _category == null ? null : _categoryKarat(_category!);
  double? get _lockedWage =>
      _category == null ? null : _categoryWage(_category!);

  @override
  void dispose() {
    _weight.dispose();
    _wage.dispose();
    _count.dispose();
    _amount.dispose();
    _categoryFocus.dispose();
    _weightFocus.dispose();
    _wageFocus.dispose();
    super.dispose();
  }

  void _choose(Map<String, dynamic> category) {
    setState(() {
      _category = category;
      _error = null;
      final k = _categoryKarat(category);
      if (k != null) _karat = k;
      final w = _categoryWage(category);
      _wage.text = w == null
          ? '0'
          : w.toStringAsFixed(w.truncateToDouble() == w ? 0 : 2);
    });
    _weightFocus.requestFocus();
  }

  void _add() {
    final category = _category;
    final weight = readTypedNumber(_weight.text) ?? 0;
    if (category == null) {
      setState(() => _error = 'اختر التصنيف');
      _categoryFocus.requestFocus();
      return;
    }
    if (weight <= 0) {
      setState(() => _error = 'أدخل الوزن');
      _weightFocus.requestFocus();
      return;
    }
    final amount = readTypedNumber(_amount.text);
    widget.onAdd(
      SalesCategoryEntry(
        category: category,
        karat: _lockedKarat ?? _karat,
        weight: weight,
        wage: _lockedWage ?? readTypedNumber(_wage.text) ?? 0,
        count:
            int.tryParse(
              readTypedNumber(_count.text)?.toInt().toString() ?? '',
            ) ??
            1,
        amount: (amount != null && amount > 0) ? amount : null,
      ),
    );
    setState(() => _error = null);
    _weight.clear();
    _amount.clear();
    _weightFocus.requestFocus();
  }

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    border: const OutlineInputBorder(),
    isDense: true,
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedKarat = _lockedKarat;
    final lockedWage = _lockedWage;

    final category = RawAutocomplete<Map<String, dynamic>>(
      focusNode: _categoryFocus,
      textEditingController: _categoryText ??= TextEditingController(),
      displayStringForOption: (c) => '${c['name'] ?? ''}',
      optionsBuilder: (value) {
        final q = value.text.trim().toLowerCase();
        if (q.isEmpty) return widget.categories.take(8);
        return widget.categories
            .where((c) => '${c['name'] ?? ''}'.toLowerCase().contains(q))
            .take(8);
      },
      onSelected: _choose,
      fieldViewBuilder: (context, controller, focus, onSubmit) => TextField(
        key: const Key('sales-entry-category'),
        controller: controller,
        focusNode: focus,
        decoration: _decoration('التصنيف'),
        textInputAction: TextInputAction.next,
        onChanged: (_) {
          if (_category != null) setState(() => _category = null);
        },
        onSubmitted: (_) {
          // Enter on a typed name takes the first match.
          final q = controller.text.trim().toLowerCase();
          final first = widget.categories.where(
            (c) => '${c['name'] ?? ''}'.toLowerCase().contains(q),
          );
          if (_category == null && q.isNotEmpty && first.isNotEmpty) {
            controller.text = '${first.first['name']}';
            _choose(first.first);
          }
        },
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: AlignmentDirectional.topStart,
        child: Material(
          elevation: 4,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 240, maxWidth: 320),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final option in options)
                  ListTile(
                    dense: true,
                    title: Text('${option['name'] ?? ''}'),
                    trailing: _categoryKarat(option) == null
                        ? null
                        : Text('${_categoryKarat(option)}'),
                    onTap: () => onSelected(option),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final karat = lockedKarat != null
        ? Chip(label: Text('عيار التصنيف $lockedKarat'))
        : SegmentedButton<int>(
            segments: [
              for (final k in _sellableKarats)
                ButtonSegment(value: k, label: Text('$k')),
            ],
            selected: {_karat},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _karat = s.first),
          );

    final wage = SizedBox(
      width: 110,
      child: TextField(
        controller: _wage,
        focusNode: _wageFocus,
        enabled: lockedWage == null,
        decoration: _decoration(
          lockedWage == null ? 'أجرة/جم' : 'الأجرة من التصنيف',
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: typedNumberFormatters(),
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => _weightFocus.requestFocus(),
      ),
    );

    final weight = SizedBox(
      width: 160,
      child: TextField(
        key: const Key('sales-entry-weight'),
        controller: _weight,
        focusNode: _weightFocus,
        decoration: _decoration('الوزن الكلي (جم)'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: typedNumberFormatters(),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _add(),
      ),
    );

    final count = SizedBox(
      width: 90,
      child: TextField(
        key: const Key('sales-entry-count'),
        controller: _count,
        decoration: _decoration('العدد'),
        keyboardType: TextInputType.number,
        inputFormatters: typedNumberFormatters(),
        textInputAction: TextInputAction.next,
        onSubmitted: (_) => _weightFocus.requestFocus(),
      ),
    );

    final amount = SizedBox(
      width: 150,
      child: TextField(
        key: const Key('sales-entry-amount'),
        controller: _amount,
        decoration: _decoration('الإجمالي (اختياري)'),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: typedNumberFormatters(),
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _add(),
      ),
    );

    final addButton = FilledButton.icon(
      onPressed: _add,
      icon: const Icon(Icons.keyboard_return),
      label: const Text('إضافة'),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(width: 220, child: category),
            karat,
            wage,
            count,
            weight,
            amount,
            addButton,
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(
            _error!,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }
}
