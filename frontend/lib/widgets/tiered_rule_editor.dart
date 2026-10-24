import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/bonus_rule_model.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' as cu;
import 'app_feedback.dart';

/// What a tiered bonus rule measures (the one measure, ADR-058).
const tierMeasures = {
  'points': 'النقاط',
  'sales': 'المبيعات',
  'sold_weight': 'الوزن المباع',
  'count': 'عدد الفواتير',
};

const tierPeriods = {'daily': 'يومي', 'weekly': 'أسبوعي', 'monthly': 'شهري'};

/// One tier as typed: from a threshold, per unit of the measure or a fixed
/// amount.
class TierDraft {
  TierDraft(this.from, this.value, {required this.perUnit});

  final double? from;
  final double? value;
  final bool perUnit;
}

/// A tiered rule's terms (bonus study م2; the owner, 24 Oct 2026: «كل النقاط
/// بسعر شريحتها» -- all the measure at the tier it reached). The server
/// refuses by the same rule; [error] says it before anything is sent.
class TieredTerms {
  TieredTerms(this.measure, this.period, this.tiers);

  factory TieredTerms.blank() =>
      TieredTerms('points', 'monthly', [TierDraft(null, null, perUnit: true)]);

  factory TieredTerms.of(BonusRuleModel rule) => TieredTerms(
    rule.measure ?? 'points',
    rule.period ?? 'monthly',
    [
      for (final t in rule.tiers ?? const <Map<String, dynamic>>[])
        TierDraft(
          (t['from'] as num?)?.toDouble(),
          ((t['per_unit'] ?? t['amount']) as num?)?.toDouble(),
          perUnit: t['per_unit'] != null,
        ),
    ],
  );

  final String measure;
  final String period;
  final List<TierDraft> tiers;

  String? get error {
    if (tiers.isEmpty) return 'شريحة واحدة على الأقل';
    double? last;
    for (var i = 0; i < tiers.length; i++) {
      final tier = tiers[i];
      if (tier.from == null || tier.value == null) {
        return 'الشريحة ${i + 1}: «من» والمبلغ مطلوبان';
      }
      if (tier.from! < 0 || tier.value! < 0) {
        return 'الشريحة ${i + 1}: لا تكون سالبة';
      }
      if (last != null && tier.from! <= last) {
        return 'الشريحة ${i + 1} تبدأ بعد التي قبلها';
      }
      last = tier.from;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'rule_type': 'tiered',
    'measure': measure,
    'period': period,
    'tiers': [
      for (final t in tiers)
        {'from': t.from, if (t.perUnit) 'per_unit': t.value else 'amount': t.value},
    ],
  };
}

class _Row {
  _Row(TierDraft draft)
    : from = TextEditingController(text: _typed(draft.from)),
      value = TextEditingController(text: _typed(draft.value)),
      perUnit = draft.perUnit;

  final TextEditingController from;
  final TextEditingController value;
  bool perUnit;

  static String _typed(double? v) =>
      v == null ? '' : (v == v.truncateToDouble() ? '${v.toInt()}' : '$v');

  TierDraft get draft => TierDraft(
    double.tryParse(from.text.trim()),
    double.tryParse(value.text.trim()),
    perUnit: perUnit,
  );

  void dispose() {
    from.dispose();
    value.dispose();
  }
}

/// The measure, the period and the tiers of a tiered rule, and its preview.
/// [scope] gives the rule's other terms the preview needs (its employees,
/// its cap) as the dialog holds them.
class TieredRuleEditor extends StatefulWidget {
  const TieredRuleEditor({
    super.key,
    required this.initial,
    required this.api,
    required this.scope,
    required this.onChanged,
  });

  final TieredTerms initial;
  final ApiService api;
  final Map<String, dynamic> Function() scope;
  final ValueChanged<TieredTerms> onChanged;

  @override
  State<TieredRuleEditor> createState() => _TieredRuleEditorState();
}

class _TieredRuleEditorState extends State<TieredRuleEditor> {
  late String _measure = widget.initial.measure;
  late String _period = widget.initial.period;
  late final List<_Row> _rows = [
    for (final t in widget.initial.tiers) _Row(t),
    if (widget.initial.tiers.isEmpty) _Row(TierDraft(null, null, perUnit: true)),
  ];
  Map<String, dynamic>? _preview;
  bool _previewing = false;

  TieredTerms get _terms =>
      TieredTerms(_measure, _period, [for (final r in _rows) r.draft]);

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _changed() {
    setState(() => _preview = null);
    widget.onChanged(_terms);
  }

  Future<void> _runPreview() async {
    final terms = _terms;
    if (terms.error != null) return;
    setState(() => _previewing = true);
    try {
      final answer = await widget.api.previewBonusRule({
        ...terms.toJson(),
        ...widget.scope(),
      });
      if (mounted) setState(() => _preview = answer);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e, title: 'تعذّرت المعاينة');
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final error = _terms.error;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const Key('tier-measure'),
                value: _measure,
                decoration: const InputDecoration(labelText: 'يُقاس بـ'),
                items: [
                  for (final m in tierMeasures.entries)
                    DropdownMenuItem(value: m.key, child: Text(m.value)),
                ],
                onChanged: (v) {
                  _measure = v ?? _measure;
                  _changed();
                },
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonFormField<String>(
                key: const Key('tier-period'),
                value: _period,
                decoration: const InputDecoration(labelText: 'الفترة'),
                items: [
                  for (final p in tierPeriods.entries)
                    DropdownMenuItem(value: p.key, child: Text(p.value)),
                ],
                onChanged: (v) {
                  _period = v ?? _period;
                  _changed();
                },
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'الشرائح: يُصرف ${tierMeasures[_measure]} كله بسعر الشريحة التي بلغها، '
          'ولا شيء دون الأولى.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        for (var i = 0; i < _rows.length; i++) _tierRow(context, i),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            key: const Key('tier-add'),
            onPressed: () {
              _rows.add(_Row(TierDraft(null, null, perUnit: true)));
              _changed();
            },
            icon: const Icon(Icons.add),
            label: const Text('شريحة أخرى'),
          ),
        ),
        if (error != null)
          Text(
            error,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: OutlinedButton.icon(
            key: const Key('tier-preview'),
            onPressed: error != null || _previewing ? null : _runPreview,
            icon: const Icon(Icons.visibility_outlined),
            label: const Text('معاينة: ماذا كانت ستصرف؟'),
          ),
        ),
        if (_preview != null) _previewTable(context, _preview!),
      ],
    );
  }

  Widget _tierRow(BuildContext context, int i) {
    final row = _rows[i];
    final from = TextField(
      key: Key('tier-from-$i'),
      controller: row.from,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(labelText: 'من ${tierMeasures[_measure]}'),
      onChanged: (_) => _changed(),
    );
    final kind = SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, label: Text('لكل وحدة')),
        ButtonSegment(value: false, label: Text('مبلغ ثابت')),
      ],
      selected: {row.perUnit},
      showSelectedIcon: false,
      onSelectionChanged: (v) {
        row.perUnit = v.first;
        _changed();
      },
    );
    final value = TextField(
      key: Key('tier-value-$i'),
      controller: row.value,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: const InputDecoration(labelText: 'المبلغ'),
      onChanged: (_) => _changed(),
    );
    final remove = IconButton(
      tooltip: 'حذف الشريحة',
      onPressed: _rows.length == 1
          ? null
          : () {
              _rows.removeAt(i).dispose();
              _changed();
            },
      icon: const Icon(Icons.delete_outline),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(
        builder: (context, box) => box.maxWidth >= 560
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: from),
                  const SizedBox(width: 8),
                  kind,
                  const SizedBox(width: 8),
                  Expanded(child: value),
                  remove,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(children: [Expanded(child: from), remove]),
                  const SizedBox(height: 6),
                  kind,
                  const SizedBox(height: 6),
                  value,
                ],
              ),
      ),
    );
  }

  Widget _previewTable(BuildContext context, Map<String, dynamic> preview) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final rows = ((preview['rows'] as List?) ?? const []).cast<Map>();
    final periods = <String, List<Map>>{};
    for (final r in rows) {
      periods.putIfAbsent('${r['period_start']}', () => []).add(r);
    }
    return Card.outlined(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'كانت ستصرف ${cu.formatAmount(preview['total'] as num? ?? 0)}، '
              'وصُرف ${cu.formatAmount(preview['total_paid'] as num? ?? 0)}',
              style: theme.textTheme.titleSmall,
            ),
            for (final entry in periods.entries) ...[
              const Divider(),
              Text(entry.key, style: theme.textTheme.labelLarge),
              for (final r in entry.value)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text('${r['employee']}')),
                      Text(cu.formatAmount(r['value'] as num? ?? 0, decimals: 0)),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 110,
                        child: r['tier_from'] == null
                            ? Text(
                                'لم يبلغ شريحة',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              )
                            : Text(
                                cu.formatAmount(r['amount'] as num? ?? 0),
                                style: TextStyle(color: tones.ready.fg),
                              ),
                      ),
                      SizedBox(
                        width: 110,
                        child: Text(
                          'صُرف ${cu.formatAmount(r['paid'] as num? ?? 0)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
