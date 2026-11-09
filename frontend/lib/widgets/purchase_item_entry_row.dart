import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/category_model.dart';
import 'inline_number_cell.dart';
import 'type_to_pick_field.dart';

/// One weight of one category, as the entry row hands it back.
class PurchaseItemEntry {
  /// The description typed, or the category's name.
  final String name;
  final int karat;
  final double weight;
  final double wagePerGram;
  final int categoryId;
  final String categoryName;

  const PurchaseItemEntry({
    required this.name,
    required this.karat,
    required this.weight,
    required this.wagePerGram,
    required this.categoryId,
    required this.categoryName,
  });
}

double? _readNumber(String text) => readTypedNumber(text);

List<TextInputFormatter> get _numberFormatters => typedNumberFormatters();

/// Purchase lines typed in one row, one weight after another (PURCHASE-UX-5).
///
/// The karat, the category, an optional description and the wage are chosen
/// once; Enter on the weight adds the line and brings the cursor back to the
/// weight, so the weights of one category follow each other without a
/// dialog. A line is a category of its karat, never an item (the owner, 8
/// Nov 2026): the categories offered are the karat's; the piece is registered
/// on receiving. The rare fields (stones, notes) are on each line's details.
class PurchaseItemEntryRow extends StatefulWidget {
  final List<int> karats;
  final int initialKarat;
  final ValueChanged<PurchaseItemEntry> onAdd;

  /// The categories a line may take: active, not scrap.
  final List<Category> categories;

  const PurchaseItemEntryRow({
    super.key,
    required this.karats,
    required this.initialKarat,
    required this.onAdd,
    this.categories = const [],
  });

  @override
  State<PurchaseItemEntryRow> createState() => _PurchaseItemEntryRowState();
}

class _PurchaseItemEntryRowState extends State<PurchaseItemEntryRow> {
  final _name = TextEditingController();
  final _wage = TextEditingController(text: '0');
  final _weight = TextEditingController();
  final _nameFocus = FocusNode();
  final _wageFocus = FocusNode();
  final _weightFocus = FocusNode();
  late int _karat = widget.karats.contains(widget.initialKarat)
      ? widget.initialKarat
      : widget.karats.first;
  String? _error;
  int? _categoryId;

  /// The karat's categories: a category's karat is fixed (ADR-045).
  List<Category> get _ofKarat => widget.categories
      .where((c) => double.tryParse(c.karat ?? '') == _karat.toDouble())
      .toList();

  @override
  void dispose() {
    _name.dispose();
    _wage.dispose();
    _weight.dispose();
    _nameFocus.dispose();
    _wageFocus.dispose();
    _weightFocus.dispose();
    super.dispose();
  }

  void _focus(FocusNode node, TextEditingController controller) {
    node.requestFocus();
    controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: controller.text.length,
    );
  }

  void _add() {
    final description = _name.text.trim();
    final weight = _readNumber(_weight.text) ?? 0;
    final wage = _readNumber(_wage.text) ?? 0;
    final category = _ofKarat.where((c) => c.id == _categoryId).firstOrNull;
    if (category == null) {
      setState(() => _error = 'اختر التصنيف');
      return;
    }
    if (weight <= 0) {
      setState(() => _error = 'أدخل الوزن');
      _focus(_weightFocus, _weight);
      return;
    }
    widget.onAdd(
      PurchaseItemEntry(
        name: description.isEmpty ? category.name : description,
        karat: _karat,
        weight: weight,
        wagePerGram: wage,
        categoryId: category.id!,
        categoryName: category.name,
      ),
    );
    setState(() => _error = null);
    _weight.clear();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LayoutBuilder(
          builder: (context, box) {
            final ofKarat = _ofKarat;
            // Found by typing, as the sale's (the owner, 9 Nov 2026: «فاتورة
            // شراء لا تدعم البحث في قائمة التصنيفات مثل فاتورة البيع»).
            final category = TypeToPickField(
              fieldKey: const Key('purchase-entry-category'),
              items: [
                for (final c in ofKarat) {'id': c.id, 'name': c.name},
              ],
              selectedId: ofKarat.any((c) => c.id == _categoryId)
                  ? _categoryId
                  : null,
              labelOf: (c) => '${c['name'] ?? ''}',
              labelText: 'التصنيف',
              hintText: ofKarat.isEmpty
                  ? 'لا تصنيف لعيار $_karat'
                  : 'اكتب للبحث أو اختر',
              enabled: ofKarat.isNotEmpty,
              onSelected: (c) => setState(() {
                _categoryId = c['id'] as int?;
                _error = null;
              }),
            );
            final name = TextField(
              key: const Key('purchase-entry-name'),
              controller: _name,
              focusNode: _nameFocus,
              decoration: _decoration('الوصف (اختياري)'),
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _focus(_wageFocus, _wage),
            );
            final karat = SegmentedButton<int>(
              segments: [
                for (final k in widget.karats)
                  ButtonSegment(value: k, label: Text('$k')),
              ],
              selected: {_karat},
              showSelectedIcon: false,
              // another karat, another category: the chosen one is its own
              onSelectionChanged: (s) => setState(() {
                _karat = s.first;
                _categoryId = null;
              }),
            );
            final wage = TextField(
              key: const Key('purchase-entry-wage'),
              controller: _wage,
              focusNode: _wageFocus,
              decoration: _decoration('أجرة/جم'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: _numberFormatters,
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _focus(_weightFocus, _weight),
            );
            final weight = TextField(
              key: const Key('purchase-entry-weight'),
              controller: _weight,
              focusNode: _weightFocus,
              decoration: _decoration('الوزن (جم)'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: _numberFormatters,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _add(),
            );
            final add = FilledButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.keyboard_return),
              label: const Text('إضافة'),
            );
            final rest = <Widget>[
              karat,
              SizedBox(width: 100, child: wage),
              SizedBox(width: 120, child: weight),
              add,
            ];
            // A phone: one field a line, the screen's width, the wage and
            // the weight side by side (the owner, 9 Nov 2026: «هاتف ايفون»).
            if (box.maxWidth < 480) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  category,
                  const SizedBox(height: 8),
                  name,
                  const SizedBox(height: 8),
                  karat,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: wage),
                      const SizedBox(width: 8),
                      Expanded(child: weight),
                    ],
                  ),
                  const SizedBox(height: 8),
                  add,
                ],
              );
            }
            // One line when it fits, the category and the description
            // taking what is left.
            if (box.maxWidth >= 760) {
              return Row(
                children: [
                  Expanded(flex: 3, child: category),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: name),
                  for (final w in rest) ...[const SizedBox(width: 8), w],
                ],
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(width: 220, child: category),
                SizedBox(width: 180, child: name),
                ...rest,
              ],
            );
          },
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
