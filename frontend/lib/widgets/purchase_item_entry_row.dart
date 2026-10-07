import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils.dart';

/// One weight of one item, as the entry row hands it back.
class PurchaseItemEntry {
  final String name;
  final int karat;
  final double weight;
  final double wagePerGram;

  const PurchaseItemEntry({
    required this.name,
    required this.karat,
    required this.weight,
    required this.wagePerGram,
  });
}

double? _readNumber(String text) =>
    double.tryParse(normalizeNumber(text).trim());

List<TextInputFormatter> get _numberFormatters => [
  NormalizeNumberFormatter(),
  FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$')),
];

/// Purchase items typed in one row, one weight after another (PURCHASE-UX-5).
///
/// The name, the karat and the wage are typed once; Enter on the weight adds
/// the line and brings the cursor back to the weight, so the weights of one
/// item follow each other without a dialog. The rare fields (code, barcode,
/// stones, notes) are on each line's details.
class PurchaseItemEntryRow extends StatefulWidget {
  final List<int> karats;
  final int initialKarat;
  final ValueChanged<PurchaseItemEntry> onAdd;

  const PurchaseItemEntryRow({
    super.key,
    required this.karats,
    required this.initialKarat,
    required this.onAdd,
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
    final name = _name.text.trim();
    final weight = _readNumber(_weight.text) ?? 0;
    final wage = _readNumber(_wage.text) ?? 0;
    if (name.isEmpty) {
      setState(() => _error = 'اكتب اسم الصنف');
      _focus(_nameFocus, _name);
      return;
    }
    if (weight <= 0) {
      setState(() => _error = 'أدخل الوزن');
      _focus(_weightFocus, _weight);
      return;
    }
    widget.onAdd(
      PurchaseItemEntry(
        name: name,
        karat: _karat,
        weight: weight,
        wagePerGram: wage,
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
            final name = TextField(
              key: const Key('purchase-entry-name'),
              controller: _name,
              focusNode: _nameFocus,
              decoration: _decoration('الصنف'),
              textInputAction: TextInputAction.next,
              onSubmitted: (_) => _focus(_wageFocus, _wage),
            );
            final rest = <Widget>[
              SegmentedButton<int>(
                segments: [
                  for (final k in widget.karats)
                    ButtonSegment(value: k, label: Text('$k')),
                ],
                selected: {_karat},
                showSelectedIcon: false,
                onSelectionChanged: (s) => setState(() => _karat = s.first),
              ),
              SizedBox(
                width: 100,
                child: TextField(
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
                ),
              ),
              SizedBox(
                width: 120,
                child: TextField(
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
                ),
              ),
              FilledButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.keyboard_return),
                label: const Text('إضافة'),
              ),
            ];
            // One line when it fits, the name taking what is left.
            if (box.maxWidth >= 640) {
              return Row(
                children: [
                  Expanded(child: name),
                  for (final w in rest) ...[const SizedBox(width: 8), w],
                ],
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(width: 220, child: name),
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

/// A number edited where it is shown, in a table cell. It is taken when the
/// field is left or Enter is pressed; a value the cell does not allow puts
/// the last one back.
class InlineNumberCell extends StatefulWidget {
  final double value;
  final int fractionDigits;
  final bool allowZero;
  final String label;
  final ValueChanged<double> onChanged;

  const InlineNumberCell({
    super.key,
    required this.value,
    required this.fractionDigits,
    required this.label,
    required this.onChanged,
    this.allowZero = true,
  });

  @override
  State<InlineNumberCell> createState() => _InlineNumberCellState();
}

class _InlineNumberCellState extends State<InlineNumberCell> {
  late final _controller = TextEditingController(text: _shown(widget.value));
  final _focus = FocusNode();

  String _shown(double v) => v.toStringAsFixed(widget.fractionDigits);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus) _commit();
    });
  }

  @override
  void didUpdateWidget(InlineNumberCell old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && old.value != widget.value) {
      _controller.text = _shown(widget.value);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _commit() {
    final v = _readNumber(_controller.text);
    if (v == null || v < 0 || (!widget.allowZero && v == 0)) {
      _controller.text = _shown(widget.value);
      return;
    }
    _controller.text = _shown(v);
    if (_shown(v) != _shown(widget.value)) widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 96,
      child: TextField(
        controller: _controller,
        focusNode: _focus,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: widget.label,
        ),
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: _numberFormatters,
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
