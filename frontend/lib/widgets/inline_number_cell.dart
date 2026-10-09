import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils.dart';

/// A number as typed: Arabic digits, «٫», a thousands mark «,» «،» «٬»
/// (which is dropped) -- «1,000» was read as nothing, or as 1.000. The one
/// reader of a typed amount.
double? readTypedNumber(String text) => double.tryParse(
  normalizeNumber(text).replaceAll(',', '').replaceAll('،', '').trim(),
);

List<TextInputFormatter> typedNumberFormatters() => [
  NormalizeNumberFormatter(),
  FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$')),
];

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
    final v = readTypedNumber(_controller.text);
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
        inputFormatters: typedNumberFormatters(),
        onSubmitted: (_) => _commit(),
      ),
    );
  }
}
