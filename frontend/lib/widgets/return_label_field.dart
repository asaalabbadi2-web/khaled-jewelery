import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart' show formatGrams;
import 'reader_capture.dart';
import 'scan_field.dart';

/// A returned piece's label, as the return will say it to the server.
class ReturnLabel {
  const ReturnLabel.read(this.value) : missing = false;
  const ReturnLabel.missing()
      : value = null,
        missing = true;

  /// Its tag, or its printed number.
  final String? value;
  final bool missing;

  Map<String, dynamic> toPayload() => missing ? {'missing': true} : {'value': value};
}

/// A piece of the return as the door sees it: its number, whether it is returned, its label so far.
typedef ReturnLabelTarget = ({String itemCode, bool chosen, ReturnLabel? label});

/// «بطاقات القطع المرتجعة» -- one door for every piece of a sale return (ADR-097, the sale return; the
/// owner, 26 Nov 2026). A field a row moved the focus from row to row: the keyboard opened and the
/// screen was pulled each time, and a label read before the last was answered fell into the wrong
/// row. Here each label read -- its tag, or its printed number -- is asked of the server and goes to
/// its own piece's row, in any order, nothing moving ([ScanField]):
///
/// - its active tag: it comes back with its label; its paper alone: its tag read by the first count;
/// - a piece not of this return, one not chosen in a part returned -- not chosen for the user, what
///   is returned is theirs to choose -- or one already read: said, nothing changed.
///
/// «البطاقة مفقودة أو تالفة» is each row's ([ReturnLabelState]).
class ReturnLabelsScan extends StatelessWidget {
  const ReturnLabelsScan({super.key, required this.api, required this.targets, required this.onRead});

  final ApiService api;

  /// The pieces as they are when a label is read.
  final List<ReturnLabelTarget> Function() targets;

  /// A piece's label read: its number, its label, what is said on its row.
  final void Function(String itemCode, ReturnLabel label, String words) onRead;

  Future<ScanSaid> _read(String value, {required bool typed}) async {
    final tag = ReaderCapture.isTag(value);
    final Map<String, dynamic> body;
    try {
      body = tag ? await api.pieceByTag(value) : await api.lookupPiece(value);
    } on ApiException catch (e) {
      return (ok: false, words: isolateLatin(e.message));
    }
    final piece = (body['piece'] as Map?) ?? const {};
    final code = '${piece['item_code'] ?? ''}';
    final target = targets().where((t) => t.itemCode == code).firstOrNull;
    if (target == null) return (ok: false, words: 'القطعة $code ليست من قطع هذا المرتجع');
    if (!target.chosen) {
      return (ok: false, words: 'القطعة $code ليست ضمن المرتجع — اخترها أولًا إن كانت تُرجَع');
    }
    if (target.label != null && !target.label!.missing) {
      return (ok: false, words: 'قُرئت بطاقة $code من قبل');
    }
    // what is in the hand, at a glance: its weight and its model (the owner's rehearsal, 23 Nov 2026)
    final weight = piece['weight'] as num?;
    final model = (piece['model'] as Map?)?['name'];
    final seen = [
      if (weight != null) '${formatGrams(weight, decimals: 2)} جم',
      if (model != null) '$model',
    ].join(' · ');
    final also = seen.isEmpty ? '' : ' · $seen';
    final words = tag
        ? isolateLatin('رقاقة القطعة — تعود ببطاقتها$also')
        : isolateLatin('الرقم المطبوع للقطعة — تُقرأ رقاقتها في أول جرد بالمسح$also');
    // a printed number typed as «7» is said to the server as the piece's own number
    onRead(code, ReturnLabel.read(tag ? value.toUpperCase() : code), words);
    return (ok: true, words: 'قُرئت بطاقة $code');
  }

  @override
  Widget build(BuildContext context) => ScanField(
        keyBase: 'return-labels-scan',
        label: 'بطاقات القطع المرتجعة',
        hint: 'امسح بطاقة كل قطعة بالقارئ، بأي ترتيب',
        onValue: _read,
      );
}

/// A returned piece's label on its row: unread, read -- and how -- or «البطاقة مفقودة أو تالفة»,
/// printed again after the return is saved. Its parts' keys: words `keyBase-state`, its chip
/// `keyBase-missing`.
class ReturnLabelState extends StatelessWidget {
  const ReturnLabelState({
    super.key,
    required this.keyBase,
    required this.itemCode,
    required this.label,
    required this.words,
    required this.onMissing,
  });

  final String keyBase;
  final String itemCode;
  final ReturnLabel? label;

  /// What the door said of its label when read.
  final String? words;
  final ValueChanged<bool> onMissing;

  @override
  Widget build(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final theme = Theme.of(context);
    final label = this.label;
    final missing = label?.missing == true;
    final read = label != null && !missing;
    final tone = missing ? tones.info : (read ? tones.ready : tones.warning);
    final said = missing
        ? 'تُطبع للقطعة بطاقة جديدة بعد حفظ المرتجع'
        : (read ? (words ?? 'قُرئت بطاقتها') : isolateLatin('بطاقة القطعة $itemCode لم تُقرأ بعد'));
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(missing ? Icons.print_outlined : (read ? Icons.verified_outlined : Icons.sensors),
              size: 18, color: tone.fg),
          const SizedBox(width: 6),
          Flexible(
            child: Text(said, key: Key('$keyBase-state'), style: theme.textTheme.bodySmall?.copyWith(color: tone.fg)),
          ),
        ]),
        FilterChip(
          key: Key('$keyBase-missing'),
          label: const Text('البطاقة مفقودة أو تالفة'),
          selected: missing,
          onSelected: onMissing,
        ),
      ],
    );
  }
}
