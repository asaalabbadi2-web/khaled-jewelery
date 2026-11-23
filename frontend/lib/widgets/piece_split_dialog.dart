import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart' show formatAmount, formatGrams;
import 'app_feedback.dart';
import 'inline_number_cell.dart' show readTypedNumber, typedNumberFormatters;
import 'piece_label_actions.dart';

/// What a split gave back: the server's split, and the parts chosen for the
/// invoice (the sale's; none elsewhere).
class PieceSplitDone {
  const PieceSplitDone(this.split, this.chosen);
  final Map<String, dynamic> split;
  final List<Map<String, dynamic>> chosen;
}

/// «تفكيك القطعة» (ADR-099; the owner, 23 Nov 2026): a composite piece --
/// a set with one tag -- split, each part weighed on its own («الباقي يسجل
/// كل جزء منفرد»). The seller picks each part's category and types its
/// weight; every answer is the server's, asked as they type
/// (`/split/check`): each part's share of the wage, the parts' total against
/// the piece, the difference allowed (0.05 g) and where it goes, or why not.
/// «اعتماد» waits for an answer that is not a refusal, and a reason.
///
/// With [choose] (the sale invoice's «بيع جزء منه»), the split made, it asks
/// which parts go into the invoice; the rest stay in the stock.
///
/// A part that is a piece is born with its label to print (ADR-097 law 1):
/// printed at once, or waiting in the labels' queue -- the station's choice,
/// «طباعة تلقائية» or «تسجيل فقط» (the owner, 23 Nov 2026: «الطباعة تلقائيًا
/// بعد التفكيك بخيار»).
class PieceSplitDialog extends StatefulWidget {
  const PieceSplitDialog({
    super.key,
    required this.api,
    required this.pieceId,
    required this.code,
    required this.grams,
    required this.karat,
    required this.categories,
    this.choose = false,
  });

  final ApiService api;
  final int pieceId;
  final String code;
  final double grams;
  final int karat;

  /// The shop's categories: those a part may go to -- running, not scrap, of
  /// the piece's karat -- are offered; the server judges again.
  final List<Map<String, dynamic>> categories;
  final bool choose;

  static Future<PieceSplitDone?> show(
    BuildContext context, {
    required ApiService api,
    required int pieceId,
    required String code,
    required double grams,
    required int karat,
    required List<Map<String, dynamic>> categories,
    bool choose = false,
  }) =>
      showDialog<PieceSplitDone>(
        context: context,
        barrierDismissible: false,
        builder: (_) => PieceSplitDialog(
          api: api,
          pieceId: pieceId,
          code: code,
          grams: grams,
          karat: karat,
          categories: categories,
          choose: choose,
        ),
      );

  /// How long typing waits before the server is asked.
  static const askAfter = Duration(milliseconds: 350);

  @override
  State<PieceSplitDialog> createState() => _PieceSplitDialogState();
}

class _Part {
  int? categoryId;
  final weight = TextEditingController();
  final stones = TextEditingController();

  void dispose() {
    weight.dispose();
    stones.dispose();
  }
}

class _PieceSplitDialogState extends State<PieceSplitDialog> {
  final List<_Part> _parts = [_Part(), _Part()];
  final _reason = TextEditingController();
  bool _autoPrint = true;

  Map<String, dynamic>? _check;
  String? _refused;
  Timer? _wait;
  int _asked = 0;

  bool _saving = false;
  String? _requestKey;
  Map<String, dynamic>? _done;
  final Set<int> _chosen = {};

  late final List<Map<String, dynamic>> _offered = widget.categories.where((c) {
    if (c['is_active'] == false || c['is_scrap'] == true) return false;
    final karat = int.tryParse('${c['karat'] ?? ''}'.trim());
    return karat == null || karat == widget.karat;
  }).toList();

  @override
  void dispose() {
    _wait?.cancel();
    for (final p in _parts) {
      p.dispose();
    }
    _reason.dispose();
    super.dispose();
  }

  /// The parts as typed -- or null while one lacks its category or weight.
  List<Map<String, dynamic>>? _payload() {
    final out = <Map<String, dynamic>>[];
    for (final p in _parts) {
      final weight = readTypedNumber(p.weight.text);
      if (p.categoryId == null || weight == null || weight <= 0) return null;
      out.add({
        'category_id': p.categoryId,
        'weight': weight,
        'stones_weight': readTypedNumber(p.stones.text) ?? 0,
      });
    }
    return out;
  }

  void _changed() {
    _wait?.cancel();
    setState(() {
      _check = null;
      _refused = null;
    });
    if (_payload() == null) return;
    _wait = Timer(PieceSplitDialog.askAfter, _ask);
  }

  Future<void> _ask() async {
    final parts = _payload();
    if (parts == null) return;
    final asked = ++_asked;
    try {
      final body = await widget.api.checkPieceSplit(widget.pieceId, parts);
      if (!mounted || asked != _asked) return;
      setState(() {
        _check = (body['split'] as Map?)?.cast<String, dynamic>();
        _refused = (body['refused'] as Map?)?['message']?.toString();
      });
    } catch (e) {
      if (!mounted || asked != _asked) return;
      setState(() => _refused = AppFeedback.messageOf(e));
    }
  }

  /// Whether a part's category is tracked by the piece: a piece is born, its label to print.
  bool get _bornPieces => _parts.any((p) =>
      _offered.any((c) => c['id'] == p.categoryId && c['tracking'] == 'piece'));

  /// Each piece born of the split, its label's job: printed now, or waiting.
  void _labels(Map<String, dynamic> split) {
    final outer = Navigator.of(context).context;
    final labels = PieceLabelActions(api: widget.api, onLabel: (_, _) {}, onBusy: (_, _) {});
    for (final part in (split['parts'] as List).cast<Map<String, dynamic>>()) {
      if (part['piece_id'] != null) {
        unawaited(labels.print(outer, {'id': part['piece_id']}, run: _autoPrint));
      }
    }
  }

  bool get _ready => _check != null && _refused == null && _reason.text.trim().isNotEmpty && !_saving;

  Future<void> _confirm() async {
    final parts = _payload();
    if (parts == null) return;
    _requestKey ??= '${Random.secure().nextInt(0x7fffffff)}-${Random.secure().nextInt(0x7fffffff)}';
    setState(() => _saving = true);
    try {
      final body = await widget.api.splitPiece(widget.pieceId,
          parts: parts, reason: _reason.text.trim(), requestKey: _requestKey!);
      if (!mounted) return;
      final split = (body['split'] as Map).cast<String, dynamic>();
      _labels(split);
      if (!widget.choose) {
        Navigator.of(context).pop(PieceSplitDone(split, const []));
        return;
      }
      setState(() {
        _done = split;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _refused = AppFeedback.messageOf(e);
      });
    }
  }

  String _grams(num v) => ltrIsolate('${formatGrams(v, decimals: 2)} جم');

  Widget _summary(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final check = _check;
    final (String words, SemanticTone tone, IconData icon) = switch ((check, _refused)) {
      (_, final String refused) => (refused, tones.blocked, Icons.block),
      (null, _) => _payload() == null
          ? ('اختر تصنيف كل جزء واكتب وزنه', tones.info, Icons.scale_outlined)
          : ('يُحسب…', tones.info, Icons.hourglass_empty),
      (final Map<String, dynamic> c, _) => (
          _differenceWords(c),
          ((c['difference'] as num?) ?? 0) == 0 ? tones.ready : tones.warning,
          ((c['difference'] as num?) ?? 0) == 0 ? Icons.check_circle_outline : Icons.info_outline,
        ),
    };
    return Container(
      key: const Key('split-summary'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: tone.fg),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, color: tone.onContainer),
        const SizedBox(width: 8),
        Expanded(
          child: Text(words, style: theme.textTheme.bodyMedium?.copyWith(color: tone.onContainer)),
        ),
      ]),
    );
  }

  String _differenceWords(Map<String, dynamic> c) {
    final total = (c['total'] as num?) ?? 0;
    final grams = (c['grams'] as num?) ?? widget.grams;
    final difference = (c['difference'] as num?) ?? 0;
    final head = 'المجموع ${_grams(total)} من ${_grams(grams)}';
    if (difference == 0) return '$head — مطابق';
    if (difference < 0) return '$head — فرق ${_grams(-difference)} يُسجَّل خسارة وزن';
    return '$head — زيادة ${_grams(difference)} تُسجَّل زيادة جرد';
  }

  /// Below this width a part is two lines -- its category, then its figures:
  /// in one line the reader's and a phone's dialog cut them (the owner's
  /// rehearsal, 23 Nov 2026: «ديالوج تفكيك القطعة غير سليم»).
  static const narrow = 560.0;

  Widget _partRow(BuildContext context, int n, {required bool compact}) {
    final p = _parts[n];
    final share = (_check?['parts'] as List?)?.elementAtOrNull(n) as Map?;
    final category = DropdownButtonFormField<int>(
      key: Key('split-part-category-$n'),
      initialValue: p.categoryId,
      isExpanded: true,
      decoration: InputDecoration(labelText: 'الجزء ${n + 1}: التصنيف', isDense: true),
      items: [
        for (final c in _offered)
          DropdownMenuItem<int>(
            value: c['id'] as int,
            child: Text('${c['name']}', overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (v) {
        p.categoryId = v;
        _changed();
      },
    );
    Widget number(String key, TextEditingController controller, String label, {String? suffix}) => TextField(
          key: Key(key),
          controller: controller,
          textDirection: TextDirection.ltr,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: typedNumberFormatters(),
          decoration: InputDecoration(labelText: label, suffixText: suffix, isDense: true),
          onChanged: (_) => _changed(),
        );
    final weight = number('split-part-weight-$n', p.weight, 'الوزن', suffix: 'جم');
    final stones = number('split-part-stones-$n', p.stones, 'فصوص');
    // its share of the piece's wage by its weight, the server's -- never typed
    // (the owner, 23 Nov 2026: «الأجرة تشتق من القطعة المفككة»)
    final wage = InputDecorator(
            decoration: const InputDecoration(labelText: 'الأجرة', isDense: true),
            child: Text(
              share == null ? '—' : ltrIsolate(formatAmount(share['wage'] as num)),
              key: Key('split-part-share-$n'),
            ),
          );
    final remove = IconButton(
      key: Key('split-part-remove-$n'),
      tooltip: 'حذف الجزء',
      icon: const Icon(Icons.close),
      onPressed: _parts.length <= 2
          ? null
          : () {
              setState(() => _parts.removeAt(n).dispose());
              _changed();
            },
    );
    if (compact) {
      return Padding(
        key: Key('split-part-$n'),
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [Expanded(child: category), remove]),
          const SizedBox(height: 6),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(flex: 4, child: weight),
            const SizedBox(width: 8),
            Expanded(flex: 3, child: stones),
            const SizedBox(width: 8),
            Expanded(flex: 4, child: wage),
          ]),
        ]),
      );
    }
    return Padding(
      key: Key('split-part-$n'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 3, child: category),
        const SizedBox(width: 8),
        SizedBox(width: 96, child: weight),
        const SizedBox(width: 8),
        SizedBox(width: 84, child: stones),
        const SizedBox(width: 8),
        SizedBox(width: 104, child: wage),
        remove,
      ]),
    );
  }

  Widget _editing(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${_grams(widget.grams)} · عيار ${widget.karat} — زِن كل جزء على الميزان واختر تصنيفه',
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        // by the screen's width: a dialog sizes to its content, no LayoutBuilder in it
        for (var n = 0; n < _parts.length; n++)
          _partRow(context, n, compact: MediaQuery.sizeOf(context).width < narrow + 80),
        Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          TextButton.icon(
            key: const Key('split-add-part'),
            icon: const Icon(Icons.add),
            label: const Text('إضافة جزء'),
            onPressed: () {
              setState(() => _parts.add(_Part()));
              _changed();
            },
          ),
        ]),
        if (_bornPieces) ...[
          const SizedBox(height: 4),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('بطاقات القطع الجديدة'),
            const SizedBox(height: 4),
            SegmentedButton<bool>(
              key: const Key('split-print-mode'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(value: true, label: Text('طباعة تلقائية')),
                ButtonSegment(value: false, label: Text('تسجيل فقط')),
              ],
              selected: {_autoPrint},
              onSelectionChanged: (v) => setState(() => _autoPrint = v.first),
            ),
          ]),
        ],
        const SizedBox(height: 8),
        _summary(context),
        const SizedBox(height: 12),
        TextField(
          key: const Key('split-reason'),
          controller: _reason,
          maxLength: 200,
          decoration: const InputDecoration(labelText: 'سبب التفكيك', hintText: 'مثل: الزبون يريد العقد والحلق'),
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _choosing(BuildContext context) {
    final done = _done!;
    final parts = (done['parts'] as List).cast<Map<String, dynamic>>();
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('أيّ الأجزاء تُضاف إلى الفاتورة؟ الباقي يبقى في المخزون.',
          style: Theme.of(context).textTheme.bodyMedium),
      const SizedBox(height: 8),
      for (var n = 0; n < parts.length; n++)
        CheckboxListTile(
          key: Key('split-choose-$n'),
          value: _chosen.contains(n),
          onChanged: (v) => setState(() => v == true ? _chosen.add(n) : _chosen.remove(n)),
          title: Text('${parts[n]['category_name']} · ${_grams(parts[n]['weight'] as num)}'),
          subtitle: parts[n]['item_code'] == null
              ? null
              : Text(isolateLatin('قطعة جديدة ${parts[n]['item_code']} — '
                  '${_autoPrint ? 'بطاقتها تُطبع الآن' : 'بطاقتها في قائمة انتظار الطباعة'}')),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final done = _done;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        // a phone's and the reader's width given to the parts, not to the margins
        insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        title: Text(done == null
            ? isolateLatin('تفكيك القطعة ${widget.code}')
            : isolateLatin('فُكِّكت ${widget.code} — القيد ${done['entry_number'] ?? ''}')),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: SingleChildScrollView(child: done == null ? _editing(context) : _choosing(context)),
        ),
        actions: done == null
            ? [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.of(context).pop(),
                  child: const Text('إلغاء'),
                ),
                FilledButton(
                  key: const Key('split-confirm'),
                  onPressed: _ready ? _confirm : null,
                  child: Text(_saving ? 'يُفكَّك…' : 'اعتماد التفكيك'),
                ),
              ]
            : [
                TextButton(
                  key: const Key('split-add-none'),
                  onPressed: () => Navigator.of(context).pop(PieceSplitDone(done, const [])),
                  child: const Text('لا شيء الآن'),
                ),
                FilledButton(
                  key: const Key('split-add-chosen'),
                  onPressed: _chosen.isEmpty
                      ? null
                      : () {
                          final parts = (done['parts'] as List).cast<Map<String, dynamic>>();
                          Navigator.of(context).pop(PieceSplitDone(done, [
                            for (var n = 0; n < parts.length; n++)
                              if (_chosen.contains(n)) parts[n],
                          ]));
                        },
                  child: const Text('إضافة المختار إلى الفاتورة'),
                ),
              ],
      ),
    );
  }
}
