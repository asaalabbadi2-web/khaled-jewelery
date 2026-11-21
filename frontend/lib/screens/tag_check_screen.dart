import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../widgets/app_feedback.dart';
import '../widgets/reader_capture.dart';

/// «تحقّق من بطاقة» on the handheld reader (ADR-085 ت2 ج2): one label read --
/// its tag, or its printed code -- and what it is to the server: its piece,
/// its facts, where the books have it, its tag's state and generation. A tag
/// of a print attempt whose end is not known is settled here by that very
/// reading (ADR-097 law 10); the server matches it. Nothing else is written.
class TagCheckScreen extends StatefulWidget {
  const TagCheckScreen({super.key, this.api});
  final ApiService? api;

  @override
  State<TagCheckScreen> createState() => _TagCheckScreenState();
}

/// One value read and what the server said of it.
typedef TagCheck = ({
  String value,
  Map<String, dynamic>? piece,
  Map<String, dynamic>? tag,
  String? place,
  String? words,
});

class _TagCheckScreenState extends State<TagCheckScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  late final ReaderCapture _capture = ReaderCapture(onEvents: _took, clearAfterRead: true);
  final _focus = FocusNode();
  final List<TagCheck> _checks = [];
  bool _asking = false;

  @override
  void initState() {
    super.initState();
    _capture.start();
  }

  @override
  void dispose() {
    _capture.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// The last value read is the one asked: a label checked is one label.
  void _took(List<ReaderEvent> events) {
    final reads = events.where((e) => e.kind == 'read').toList();
    if (reads.isEmpty) return;
    _ask(reads.last.value!);
  }

  Future<void> _ask(String value) async {
    if (_asking) return;
    setState(() => _asking = true);
    TagCheck check;
    try {
      final body = value.startsWith('KJ-') ? await _api.lookupPiece(value) : await _api.pieceByTag(value);
      check = (
        value: value,
        piece: body['piece'] as Map<String, dynamic>?,
        tag: body['tag'] as Map<String, dynamic>?,
        place: (body['location'] as Map?)?['name']?.toString(),
        words: null,
      );
    } on ApiException catch (e) {
      check = (value: value, piece: null, tag: e.details['tag'] as Map<String, dynamic>?, place: null, words: e.message);
    } catch (_) {
      check = (value: value, piece: null, tag: null, place: null, words: 'تعذّر سؤال الخادم');
    }
    if (!mounted) return;
    setState(() {
      _checks.insert(0, check);
      if (_checks.length > 5) _checks.removeLast();
      _asking = false;
    });
  }

  Future<void> _settle(TagCheck check) async {
    final attemptId = check.tag?['attempt_id'] as int?;
    if (attemptId == null) return;
    try {
      await _api.resolvePrintAttempt(attemptId, {'read_value': check.value});
      if (!mounted) return;
      AppFeedback.success(context, 'اعتُمدت البطاقة');
      setState(() => _checks.remove(check));
      await _ask(check.value);
    } catch (e) {
      if (mounted) AppFeedback.error(context, e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('تحقّق من بطاقة')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('اضغط في الحقل، ثم اقرأ بطاقة واحدة بالقارئ: رقاقتها أو رمزها المطبوع.', style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          TextField(
            key: const Key('check-field'),
            controller: _capture.field,
            focusNode: _focus,
            autofocus: true,
            maxLines: 1,
            textDirection: TextDirection.ltr,
            decoration: const InputDecoration(labelText: 'ما يكتبه القارئ', isDense: true),
            onChanged: _capture.typed,
          ),
          if (_asking) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
          const SizedBox(height: 12),
          for (final c in _checks) _card(context, c),
        ]),
      ),
    );
  }

  Widget _card(BuildContext context, TagCheck c) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final state = c.tag?['state'] as String?;
    final adopted = c.piece != null && (state == null || state == 'active');
    final tone = adopted ? tones.ready : tones.warning;
    final piece = c.piece;
    final unsettled = state == 'unconfirmed' && c.tag?['unsettled'] == true;
    final generation = c.tag?['generation'];
    return Card(
      key: Key('check-${c.value}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Icon(adopted ? Icons.verified_outlined : Icons.help_outline, color: tone.fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                piece != null ? '${piece['item_code']}' : '${c.tag?['item_code'] ?? c.value}',
                textDirection: TextDirection.ltr,
                textAlign: TextAlign.right,
                style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(
            adopted
                ? (c.value.startsWith('KJ-')
                    ? 'الرمز المطبوع'
                    : 'رقاقة معتمدة${generation == null ? '' : ' — الجيل ${generation.toString().padLeft(4, '0')}'}')
                : (c.words ?? '${c.tag?['message'] ?? ''}'),
            key: Key('check-state-${c.value}'),
            style: theme.textTheme.titleSmall?.copyWith(color: tone.fg),
          ),
          if (piece != null) ...[
            const SizedBox(height: 8),
            Text([
              '${formatGrams((piece['weight'] as num? ?? 0).toDouble(), decimals: 2)} جم',
              if (((piece['stones_weight'] as num?) ?? 0) > 0)
                '${piece['stones_kind'] == 'priced' ? '+ ' : ''}فصوص ${formatGrams((piece['stones_weight'] as num).toDouble(), decimals: 2)} جم',
              if (piece['model'] != null) '${(piece['model'] as Map)['name']}',
              if (piece['size'] != null) 'مقاس ${(piece['size'] as Map)['label']}',
            ].join(' · ')),
            Text(
              piece['in_stock'] == false
                  ? 'ليست في المخزون'
                  : 'مكانها في الدفاتر: ${c.place ?? 'أكثر من موقع'}',
              key: Key('check-place-${c.value}'),
            ),
          ],
          if (unsettled) ...[
            const SizedBox(height: 12),
            FilledButton(
              key: Key('check-settle-${c.value}'),
              onPressed: () => _settle(c),
              child: const Text('اعتمد هذه البطاقة'),
            ),
          ],
        ]),
      ),
    );
  }
}
