import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/currency_utils.dart' show formatGrams;
import '../utils/scan_feedback.dart';
import '../widgets/app_feedback.dart';
import '../widgets/reader_capture.dart';
import '../widgets/reader_receiver.dart';
import '../utils/bidi.dart';

/// «تحقّق من بطاقة» on the handheld reader (ADR-085 ت2 ج2): one label read --
/// its tag, or its printed code -- and what it is to the server: its piece,
/// its facts, where the books have it, its tag's state and generation. A tag
/// of a print attempt whose end is not known is settled here by that very
/// reading (ADR-097 law 10); the server matches it. Nothing else is written.
///
/// Each press of the reader is a check of its own (the owner, 21 Nov 2026):
/// a new press empties the screen and shows what that press read -- a label
/// held under the reader is asked once, however often it is read -- and
/// «مسح» empties it by hand.
class TagCheckScreen extends StatefulWidget {
  const TagCheckScreen({super.key, this.api, this.elapsed});
  final ApiService? api;

  /// Milliseconds on the reader -- a stopwatch unless given (a test's).
  final int Function()? elapsed;

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

  /// How it left when it is not held -- «ليست في المخزون — بيعت <day>», the
  /// server's words, the count by scan's too -- and its state (sold, ...).
  String? out,
  String? outState,
});

class _TagCheckScreenState extends State<TagCheckScreen> {
  late final ApiService _api = widget.api ?? ApiService();
  late final ReaderCapture _capture = ReaderCapture(onEvents: _took, elapsed: widget.elapsed, clearAfterRead: true);
  final _focus = FocusNode();
  final List<TagCheck> _checks = [];

  /// The press shown, and the values it read -- each asked once.
  int? _press;
  final Set<String> _asked = {};
  int _asking = 0;

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

  /// A new press empties the screen; each value of the press shown is asked once.
  void _took(List<ReaderEvent> events) {
    for (final e in events) {
      if (e.press != _press) {
        _press = e.press;
        setState(() {
          _checks.clear();
          _asked.clear();
        });
      }
      final value = e.value;
      if (e.kind == 'read' && value != null && _asked.add(value)) _ask(value);
    }
  }

  void _clear() {
    setState(() {
      _checks.clear();
      _asked.clear();
      _capture.field.clear();
    });
    _focus.requestFocus();
  }

  Future<void> _ask(String value) async {
    final press = _press;
    setState(() => _asking++);
    TagCheck check;
    try {
      final body = value.startsWith('KJ-') ? await _api.lookupPiece(value) : await _api.pieceByTag(value);
      check = (
        value: value,
        piece: body['piece'] as Map<String, dynamic>?,
        tag: body['tag'] as Map<String, dynamic>?,
        place: (body['location'] as Map?)?['name']?.toString(),
        words: null,
        out: (body['out'] as Map?)?['words']?.toString(),
        outState: (body['out'] as Map?)?['state']?.toString(),
      );
    } on ApiException catch (e) {
      check = (value: value, piece: null, tag: e.details['tag'] as Map<String, dynamic>?, place: null, words: e.message,
          out: null, outState: null);
    } catch (_) {
      check = (value: value, piece: null, tag: null, place: null, words: 'تعذّر سؤال الخادم', out: null, outState: null);
    }
    if (!mounted) return;
    // the panel says the piece the server named, not the tag's raw value
    final code = check.piece?['item_code'] ?? check.tag?['item_code'];
    _capture.describe(value, code != null ? '$code' : (check.words ?? 'ليست من رموزنا'));
    final shown = press == _press && _asked.contains(value);
    setState(() {
      _asking--;
      // an answer for a press already gone is not shown on the next one
      if (shown) _checks.add(check);
    });
    // the system's word on it: a label of a piece in stock, or one to look at
    if (shown) _found(check) ? ScanFeedback.added() : ScanFeedback.refused();
  }

  /// A label of a piece in stock with its adopted tag -- the card's green.
  static bool _found(TagCheck c) {
    final state = c.tag?['state'] as String?;
    return c.piece != null && (state == null || state == 'active') && c.piece?['in_stock'] != false;
  }

  Future<void> _settle(TagCheck check) async {
    final attemptId = check.tag?['attempt_id'] as int?;
    if (attemptId == null) return;
    try {
      await _api.resolvePrintAttempt(attemptId, {'read_value': check.value});
      if (!mounted) return;
      AppFeedback.success(context, 'اعتُمدت البطاقة');
      setState(() => _checks.remove(check));
      _asked.add(check.value);
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
        appBar: AppBar(
          title: const Text('تحقّق من بطاقة'),
          actions: [
            TextButton.icon(
              key: const Key('check-clear'),
              style: TextButton.styleFrom(foregroundColor: Theme.of(context).appBarTheme.foregroundColor),
              onPressed: _clear,
              icon: const Icon(Icons.clear_all),
              label: const Text('مسح'),
            ),
          ],
        ),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          Text('اقرأ بطاقة بالقارئ: رقاقتها أو رمزها المطبوع. كل ضغطة جديدة تبدأ فحصًا جديدًا.',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 8),
          ReaderReceiver(capture: _capture, focusNode: _focus, fieldKey: const Key('check-field')),
          if (_asking > 0) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
          const SizedBox(height: 12),
          for (final c in _checks) _card(context, c),
        ]),
      ),
    );
  }

  /// The card heads with its verdict -- its words, its colour and its own
  /// icon (the owner, 22 Nov 2026, the screens by a designer's eye): in stock
  /// and where; how it left; a stopped tag; an attempt never adopted; not
  /// ours. The tag drops to a small line, its generation only in the
  /// server's words where it matters.
  ({String words, IconData icon, SemanticTone tone}) _verdict(TagCheck c, AppSemanticColors tones) {
    final state = c.tag?['state'] as String?;
    final adopted = c.piece != null && (state == null || state == 'active');
    final held = c.piece?['in_stock'] != false;
    final message = c.words ?? c.tag?['message']?.toString();
    if (adopted && held) {
      return (words: 'في المخزون — ${c.place ?? 'أكثر من موقع'}', icon: Icons.verified_outlined, tone: tones.ready);
    }
    if (adopted) {
      final icon = switch (c.outState) {
        'sold' => Icons.sell_outlined,
        'returned_to_supplier' => Icons.assignment_return_outlined,
        'split' => Icons.call_split,          // its parts are pieces or weight of their own (ADR-099)
        _ => Icons.logout,
      };
      return (words: c.out ?? 'ليست في المخزون', icon: icon, tone: tones.warning);
    }
    if (state == 'stopped') return (words: message ?? 'رقاقة ملغاة', icon: Icons.block, tone: tones.blocked);
    if (state == 'unconfirmed') {
      return (words: message ?? 'محاولة لم تُعتمد', icon: Icons.hourglass_empty, tone: tones.warning);
    }
    return (words: message ?? 'ليست من رموزنا', icon: Icons.help_outline, tone: tones.blocked);
  }

  Widget _card(BuildContext context, TagCheck c) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final state = c.tag?['state'] as String?;
    final adopted = c.piece != null && (state == null || state == 'active');
    final piece = c.piece;
    final unsettled = state == 'unconfirmed' && c.tag?['unsettled'] == true;
    final verdict = _verdict(c, tones);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Card(
      key: Key('check-${c.value}'),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(
            piece != null ? '${piece['item_code']}' : '${c.tag?['item_code'] ?? c.value}',
            textDirection: TextDirection.ltr,
            textAlign: TextAlign.right,
            style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Container(
            key: Key('check-verdict-${c.value}'),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: verdict.tone.container,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: verdict.tone.fg),
            ),
            child: Row(children: [
              Icon(verdict.icon, color: verdict.tone.onContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  isolateLatin(verdict.words),
                  key: Key('check-verdict-text-${c.value}'),
                  style: theme.textTheme.titleSmall
                      ?.copyWith(color: verdict.tone.onContainer, fontWeight: FontWeight.w800),
                ),
              ),
            ]),
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
          ],
          if (adopted) ...[
            const SizedBox(height: 4),
            Text(c.value.startsWith('KJ-') ? 'الرمز المطبوع' : 'رقاقة معتمدة',
                key: Key('check-tag-${c.value}'), style: muted),
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
