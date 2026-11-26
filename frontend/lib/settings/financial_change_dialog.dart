import 'package:flutter/material.dart';

import '../utils.dart' show NormalizeNumberFormatter;
import 'settings_editors.dart';
import 'settings_registry.dart';

/// Saves [changes] (as the server keeps them) with [reason]: no error when
/// saved, else what to say -- and whether the values it was changed from are
/// stale.
typedef FinancialSave = Future<({String? error, bool stale})> Function(Map<String, Object?> changes, String reason);

/// A financial (level-3) setting changed knowingly (settings spec v2 §7.2;
/// ADR-102, ADR-103) -- alone, or with the settings that are one policy with
/// it ([EditorSpec.group]: the office terms, priced and stamped together):
/// each value now and after, what changes and from when, how far it is
/// undone, and a reason -- required. Only what changed is saved, by the
/// caller ([save]): a refusal is said here and the dialog stays, the values
/// and the reason kept; a key another user moved since closes it ([stale]) --
/// its «الآن» is no longer now. Returns true when saved.
Future<bool?> showFinancialChange(
  BuildContext context, {
  required List<SettingEntry> entries,
  required Map<String, Object?> current,
  required FinancialSave save,
  String? title,
  String? description,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => FinancialChangeDialog(
          entries: entries, current: current, save: save, title: title, description: description),
    );

class FinancialChangeDialog extends StatefulWidget {
  const FinancialChangeDialog({
    super.key,
    required this.entries,
    required this.current,
    required this.save,
    this.title,
    this.description,
  });

  final List<SettingEntry> entries;
  final Map<String, Object?> current;
  final FinancialSave save;
  final String? title;
  final String? description;

  @override
  State<FinancialChangeDialog> createState() => _FinancialChangeDialogState();
}

class _FinancialChangeDialogState extends State<FinancialChangeDialog> {
  late final Map<String, Object?> _values = {
    for (final e in widget.entries)
      e.key!: _single && _spec(e).kind == EditorKind.toggle ? !(widget.current[e.key] == true) : widget.current[e.key],
  };
  late final Map<String, TextEditingController> _fields = {
    for (final e in widget.entries)
      if (_spec(e).kind == EditorKind.number) e.key!: TextEditingController(text: '${widget.current[e.key] ?? ''}'),
  };
  final _reason = TextEditingController();
  String? _error;
  bool _saving = false;

  bool get _single => widget.entries.length == 1;
  EditorSpec _spec(SettingEntry e) => editors[e.key]!;

  @override
  void dispose() {
    _reason.dispose();
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  List<SettingEntry> get _changed =>
      [for (final e in widget.entries) if (!_spec(e).same(widget.current[e.key], _values[e.key])) e];

  bool get _valid => widget.entries.every((e) => _spec(e).invalid(_values[e.key]) == null);

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final (:error, :stale) = await widget.save(
        {for (final e in _changed) e.key!: _spec(e).write(_values[e.key])}, _reason.text.trim());
    if (!mounted) return;
    if (error == null || stale) {
      Navigator.of(context).pop(error == null);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  void _set(String key, Object? value) => setState(() => _values[key] = value);

  Widget? _control(SettingEntry e) {
    final key = e.key!;
    final spec = _spec(e);
    switch (spec.kind) {
      case EditorKind.percent:
        final v = ((_values[key] as num?) ?? 0).toDouble().clamp(0, spec.max).toDouble();
        return Slider(
          key: const Key('financial-value'),
          value: v,
          min: 0,
          max: spec.max,
          divisions: (spec.max / spec.step).round(),
          label: spec.display(v),
          onChanged: (x) => _set(key, (x * 10).round() / 10),
        );
      case EditorKind.karats:
        return KaratChips(keyPrefix: 'financial-karat', value: _values[key], onChanged: (v) => _set(key, v));
      case EditorKind.choice:
        return Wrap(spacing: 8, runSpacing: 6, children: [
          for (final (value, label) in spec.options)
            ChoiceChip(
              key: Key('financial-choice-$key-$value'),
              label: Text(label),
              selected: _values[key] == value,
              onSelected: (_) => _set(key, value),
            ),
        ]);
      case EditorKind.number:
        return TextField(
          key: Key('financial-field-$key'),
          controller: _fields[key],
          keyboardType: TextInputType.numberWithOptions(decimal: spec.decimals > 0),
          inputFormatters: [NormalizeNumberFormatter()],
          decoration: InputDecoration(
            labelText: _single ? null : partLabel(e),
            suffixText: spec.unit.isEmpty ? null : spec.unit,
            errorText: spec.invalid(_values[key]),
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          onChanged: (v) => _set(key, v),
        );
      case EditorKind.toggle:
      case EditorKind.text:
      case EditorKind.currency:
        return null; // a toggle is changed by flipping; no text is financial
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final first = widget.entries.first;
    final description = widget.description ?? first.description;
    Widget fact(String label, String text) => Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 96,
              child: Text(label, style: theme.textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
            ),
            Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
          ]),
        );
    return AlertDialog(
      title: Text('تغيير «${widget.title ?? first.label}»'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_single)
                Row(children: [
                  Expanded(child: _side('الآن', _spec(first).display(widget.current[first.key]),
                      key: const Key('financial-before'))),
                  const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_back)),
                  Expanded(child: _side('بعد التأكيد', _spec(first).display(_values[first.key]),
                      key: const Key('financial-after'))),
                ])
              else
                for (final e in widget.entries) _groupLine(e),
              for (final e in widget.entries)
                if (_control(e) case final Widget control) ...[const SizedBox(height: 8), control],
              const SizedBox(height: 8),
              if (description.isNotEmpty) fact('ما يشمله', description),
              if (first.effect != null) fact('ما يتغيّر', first.effect!),
              if (first.revertRule != null) fact('التراجع', first.revertRule!),
              const SizedBox(height: 12),
              TextField(
                key: const Key('financial-reason'),
                controller: _reason,
                minLines: 1,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'السبب (إلزامي)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, key: const Key('financial-error'), style: TextStyle(color: cs.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: _saving ? null : () => Navigator.of(context).pop(false), child: const Text('إلغاء')),
        FilledButton(
          key: const Key('financial-confirm'),
          onPressed: _saving || _changed.isEmpty || !_valid || _reason.text.trim().isEmpty ? null : _confirm,
          child: const Text('تأكيد وحفظ'),
        ),
      ],
    );
  }

  /// A part of a group: its value now and after, marked when it changes.
  Widget _groupLine(SettingEntry e) {
    final theme = Theme.of(context);
    final spec = _spec(e);
    final changes = !spec.same(widget.current[e.key], _values[e.key]);
    final now = spec.display(widget.current[e.key]);
    return Padding(
      key: Key('financial-line-${e.key}'),
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        changes ? '${partLabel(e)}: $now ← ${spec.display(_values[e.key])}' : '${partLabel(e)}: $now',
        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: changes ? FontWeight.w700 : null),
      ),
    );
  }

  Widget _side(String label, String value, {Key? key}) {
    final theme = Theme.of(context);
    return Container(
      key: key,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        Text(value, textAlign: TextAlign.center, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      ]),
    );
  }
}

/// The karats chosen, as chips; never none -- none is 24, as the old screen
/// kept a VAT-exempt list. [onChanged] null: shown, not edited.
class KaratChips extends StatelessWidget {
  const KaratChips({super.key, required this.keyPrefix, required this.value, required this.onChanged});

  final String keyPrefix;
  final Object? value;
  final ValueChanged<List<int>>? onChanged;

  @override
  Widget build(BuildContext context) {
    final chosen = {...(value as List? ?? const [])};
    final changed = onChanged;
    return Wrap(spacing: 8, runSpacing: 6, children: [
      for (final k in karatOptions)
        FilterChip(
          key: Key('$keyPrefix-$k'),
          label: Text('عيار $k'),
          selected: chosen.contains(k),
          onSelected: changed == null
              ? null
              : (on) {
                  on ? chosen.add(k) : chosen.remove(k);
                  changed(chosen.isEmpty ? [24] : (chosen.toList().cast<int>()..sort()));
                },
        ),
    ]);
  }
}
