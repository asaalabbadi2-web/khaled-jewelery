import 'package:flutter/material.dart';

import 'settings_editors.dart';
import 'settings_registry.dart';

/// A financial (level-3) setting changed alone, knowingly (settings spec v2
/// §7.2; ADR-102, ADR-103): the value now and after, what changes and from
/// when, how far it is undone, and a reason -- required. The save is the
/// caller's ([save]): a refusal is said here and the dialog stays, the value
/// and the reason kept; a key another user moved since closes it ([stale]) --
/// its «الآن» is no longer now. Returns true when saved.
/// Saves [value] with [reason]: null when saved, else what to say -- and
/// whether the value it was changed from is stale.
typedef FinancialSave = Future<({String? error, bool stale})> Function(Object? value, String reason);

Future<bool?> showFinancialChange(
  BuildContext context, {
  required SettingEntry entry,
  required EditorSpec spec,
  required Object? current,
  required FinancialSave save,
}) =>
    showDialog<bool>(
      context: context,
      builder: (_) => FinancialChangeDialog(entry: entry, spec: spec, current: current, save: save),
    );

class FinancialChangeDialog extends StatefulWidget {
  const FinancialChangeDialog({
    super.key,
    required this.entry,
    required this.spec,
    required this.current,
    required this.save,
  });

  final SettingEntry entry;
  final EditorSpec spec;
  final Object? current;
  final FinancialSave save;

  @override
  State<FinancialChangeDialog> createState() => _FinancialChangeDialogState();
}

class _FinancialChangeDialogState extends State<FinancialChangeDialog> {
  late Object? _value = widget.spec.kind == EditorKind.toggle ? !(widget.current == true) : widget.current;
  final _reason = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _changed => !widget.spec.same(widget.current, _value);

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final (:error, :stale) = await widget.save(widget.spec.write(_value), _reason.text.trim());
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

  Widget _control() {
    final spec = widget.spec;
    switch (spec.kind) {
      case EditorKind.percent:
        final v = ((_value as num?) ?? 0).toDouble().clamp(0, spec.max).toDouble();
        return Slider(
          key: const Key('financial-value'),
          value: v,
          min: 0,
          max: spec.max,
          divisions: (spec.max / spec.step).round(),
          label: spec.display(v),
          onChanged: (x) => setState(() => _value = (x * 10).round() / 10),
        );
      case EditorKind.karats:
        return KaratChips(
            keyPrefix: 'financial-karat', value: _value, onChanged: (v) => setState(() => _value = v));
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final e = widget.entry;
    final spec = widget.spec;
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
      title: Text('تغيير «${e.label}»'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Expanded(child: _side('الآن', spec.display(widget.current), key: const Key('financial-before'))),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_back)),
                Expanded(child: _side('بعد التأكيد', spec.display(_value), key: const Key('financial-after'))),
              ]),
              if (spec.kind != EditorKind.toggle) ...[const SizedBox(height: 8), _control()],
              const SizedBox(height: 8),
              if (e.description.isNotEmpty) fact('ما يشمله', e.description),
              if (e.effect != null) fact('ما يتغيّر', e.effect!),
              if (e.revertRule != null) fact('التراجع', e.revertRule!),
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
          onPressed: _saving || !_changed || _reason.text.trim().isEmpty ? null : _confirm,
          child: const Text('تأكيد وحفظ'),
        ),
      ],
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
