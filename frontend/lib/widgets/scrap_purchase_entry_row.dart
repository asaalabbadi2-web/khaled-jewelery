import 'package:flutter/material.dart';

import 'inline_number_cell.dart';

/// One line of a scrap purchase, as the entry row hands it back.
class ScrapPurchaseEntry {
  final Map<String, dynamic> category;
  final int karat;
  final double standing;
  final double stones;

  /// What is paid for the line, or 0 to price it by its weight.
  final double amount;

  const ScrapPurchaseEntry({
    required this.category,
    required this.karat,
    required this.standing,
    required this.stones,
    required this.amount,
  });
}

const _buyableKarats = [18, 21, 22, 24];

int? _categoryKarat(Map<String, dynamic> category) {
  final k = int.tryParse('${category['karat'] ?? ''}');
  return _buyableKarats.contains(k) ? k : null;
}

/// A scrap purchase's lines typed in one row (SALES-UX-9): the category,
/// its karat, the standing weight, the stones and the amount paid; Enter adds
/// the line and returns to the standing weight. 610 of the 776 scrap
/// purchases on the 6 Oct copy are of one line, and a dialog opened for each.
/// The dialog stays for the rare fields (wage, count).
class ScrapPurchaseEntryRow extends StatefulWidget {
  final List<Map<String, dynamic>> categories;
  final int mainKarat;
  final ValueChanged<ScrapPurchaseEntry> onAdd;

  const ScrapPurchaseEntryRow({
    super.key,
    required this.categories,
    required this.mainKarat,
    required this.onAdd,
  });

  @override
  State<ScrapPurchaseEntryRow> createState() => _ScrapPurchaseEntryRowState();
}

class _ScrapPurchaseEntryRowState extends State<ScrapPurchaseEntryRow> {
  final _standing = TextEditingController();
  final _stones = TextEditingController();
  final _amount = TextEditingController();
  final _categoryText = TextEditingController();
  final _categoryFocus = FocusNode();
  final _standingFocus = FocusNode();
  final _stonesFocus = FocusNode();
  final _amountFocus = FocusNode();

  Map<String, dynamic>? _category;
  late int _karat = _buyableKarats.contains(widget.mainKarat)
      ? widget.mainKarat
      : 21;
  String? _error;

  int? get _lockedKarat =>
      _category == null ? null : _categoryKarat(_category!);

  @override
  void dispose() {
    _standing.dispose();
    _stones.dispose();
    _amount.dispose();
    _categoryText.dispose();
    _categoryFocus.dispose();
    _standingFocus.dispose();
    _stonesFocus.dispose();
    _amountFocus.dispose();
    super.dispose();
  }

  void _choose(Map<String, dynamic> category) {
    setState(() {
      _category = category;
      _error = null;
      final k = _categoryKarat(category);
      if (k != null) _karat = k;
    });
    _standingFocus.requestFocus();
  }

  void _add() {
    final category = _category;
    final standing = readTypedNumber(_standing.text) ?? 0;
    final stones = readTypedNumber(_stones.text) ?? 0;
    final amount = readTypedNumber(_amount.text) ?? 0;
    String? error;
    FocusNode? focus;
    if (category == null) {
      error = 'اختر التصنيف';
      focus = _categoryFocus;
    } else if (standing <= 0 && amount <= 0) {
      error = 'أدخل الوزن القائم أو المبلغ';
      focus = _standingFocus;
    } else if (stones > 0 && stones >= standing) {
      // A line of stones alone has no gold to buy.
      error = 'الأحجار أثقل من الوزن القائم';
      focus = _stonesFocus;
    }
    if (error != null) {
      setState(() => _error = error);
      focus?.requestFocus();
      return;
    }
    widget.onAdd(
      ScrapPurchaseEntry(
        category: category!,
        karat: _lockedKarat ?? _karat,
        standing: standing,
        stones: stones,
        amount: amount,
      ),
    );
    setState(() => _error = null);
    _standing.clear();
    _stones.clear();
    _amount.clear();
    _standingFocus.requestFocus();
  }

  InputDecoration _decoration(String label) => InputDecoration(
    labelText: label,
    border: const OutlineInputBorder(),
    isDense: true,
  );

  Widget _number({
    required String keyName,
    required TextEditingController controller,
    required FocusNode focus,
    required String label,
    required double width,
    required VoidCallback onSubmitted,
    bool last = false,
  }) => SizedBox(
    width: width,
    child: TextField(
      key: Key('scrap-entry-$keyName'),
      controller: controller,
      focusNode: focus,
      decoration: _decoration(label),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: typedNumberFormatters(),
      textInputAction: last ? TextInputAction.done : TextInputAction.next,
      onSubmitted: (_) => onSubmitted(),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lockedKarat = _lockedKarat;

    final category = RawAutocomplete<Map<String, dynamic>>(
      focusNode: _categoryFocus,
      textEditingController: _categoryText,
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
        key: const Key('scrap-entry-category'),
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
          final matches = widget.categories.where(
            (c) => '${c['name'] ?? ''}'.toLowerCase().contains(q),
          );
          if (_category == null && q.isNotEmpty && matches.isNotEmpty) {
            controller.text = '${matches.first['name']}';
            _choose(matches.first);
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
              for (final k in _buyableKarats)
                ButtonSegment(value: k, label: Text('$k')),
            ],
            selected: {_karat},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _karat = s.first),
          );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            SizedBox(width: 200, child: category),
            karat,
            _number(
              keyName: 'standing',
              controller: _standing,
              focus: _standingFocus,
              label: 'الوزن القائم (جم)',
              width: 150,
              onSubmitted: () => _stonesFocus.requestFocus(),
            ),
            _number(
              keyName: 'stones',
              controller: _stones,
              focus: _stonesFocus,
              label: 'الأحجار (جم)',
              width: 120,
              onSubmitted: () => _amountFocus.requestFocus(),
            ),
            _number(
              keyName: 'amount',
              controller: _amount,
              focus: _amountFocus,
              label: 'المبلغ',
              width: 140,
              onSubmitted: _add,
              last: true,
            ),
            FilledButton.icon(
              key: const Key('scrap-entry-add'),
              onPressed: _add,
              icon: const Icon(Icons.keyboard_return),
              label: const Text('إضافة'),
            ),
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
