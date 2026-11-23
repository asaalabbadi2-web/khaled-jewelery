import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart' show formatGrams;

/// A returned piece's label, as the return will say it to the server.
class ReturnLabel {
  const ReturnLabel.read(this.value) : missing = false;
  const ReturnLabel.missing()
      : value = null,
        missing = true;

  /// Its tag or its printed number, as read or typed.
  final String? value;
  final bool missing;

  Map<String, dynamic> toPayload() => missing ? {'missing': true} : {'value': value};
}

/// «بطاقة القطعة» in a sale return (ADR-097, the sale return; the owner,
/// 23 Nov 2026: «الزبون قد يتلف البطاقة»): the reader decides, not a person.
/// Its tag read (the reader types it here, with no Enter needed) or its
/// printed number typed is asked of the server at once -- this piece's, and
/// which: its active tag (it comes back with its label), or its paper alone
/// (its tag read by the first count). Or «البطاقة مفقودة أو تالفة»: a label
/// printed again after the return is saved. Anything else, the server's words.
/// [onSettled] says what the return sends -- null while unsettled.
class ReturnLabelField extends StatefulWidget {
  const ReturnLabelField({
    super.key,
    required this.api,
    required this.itemCode,
    required this.onSettled,
    required this.keyBase,
    this.focusNode,
    this.autofocus = false,
  });

  /// The screen's: it moves the focus to the next piece once this one is said
  /// (the owner's rehearsal, 23 Nov 2026: the reader needs no tap between pieces).
  final FocusNode? focusNode;
  final bool autofocus;

  final ApiService api;
  final String itemCode;
  final ValueChanged<ReturnLabel?> onSettled;
  /// Its parts' keys: the field is [keyBase], its chip `keyBase-missing`, its words `keyBase-state`.
  final String keyBase;

  /// A whole value as the reader types it: a tag (24 hexadecimal) or a printed number.
  static final whole = RegExp(r'^([0-9A-Fa-f]{24}|[Kk][Jj]-?[0-9]{6,})$');

  @override
  State<ReturnLabelField> createState() => _ReturnLabelFieldState();
}

class _ReturnLabelFieldState extends State<ReturnLabelField> {
  final _field = TextEditingController();
  bool _missing = false;
  bool _asking = false;
  String? _words;
  bool? _ok;
  int _asked = 0;

  @override
  void dispose() {
    _field.dispose();
    super.dispose();
  }

  void _settle(ReturnLabel? label, {required String words, required bool ok}) {
    setState(() {
      _words = words;
      _ok = ok;
      _asking = false;
    });
    widget.onSettled(label);
  }

  Future<void> _check(String typed) async {
    final value = typed.trim();
    if (value.isEmpty) return;
    final asked = ++_asked;
    setState(() => _asking = true);
    widget.onSettled(null);
    final tag = RegExp(r'^[0-9A-Fa-f]{24}$').hasMatch(value);
    try {
      final body = tag ? await widget.api.pieceByTag(value) : await widget.api.lookupPiece(value);
      if (!mounted || asked != _asked) return;
      final piece = (body['piece'] as Map?) ?? const {};
      final code = '${piece['item_code'] ?? ''}';
      // what is in the hand, at a glance: its weight and its model (the owner's rehearsal, 23 Nov 2026)
      final weight = piece['weight'] as num?;
      final model = (piece['model'] as Map?)?['name'];
      final seen = [
        if (weight != null) '${formatGrams(weight, decimals: 2)} جم',
        if (model != null) '$model',
      ].join(' · ');
      final also = seen.isEmpty ? '' : ' · $seen';
      if (code != widget.itemCode) {
        _settle(null, words: isolateLatin('البطاقة لقطعة أخرى ($code)، لا للقطعة ${widget.itemCode}'), ok: false);
        _again();
      } else if (tag) {
        _settle(ReturnLabel.read(value), words: isolateLatin('رقاقة القطعة — تعود ببطاقتها$also'), ok: true);
      } else {
        _settle(ReturnLabel.read(value),
            words: isolateLatin('الرقم المطبوع للقطعة — تُقرأ رقاقتها في أول جرد بالمسح$also'), ok: true);
      }
    } on ApiException catch (e) {
      if (!mounted || asked != _asked) return;
      _settle(null, words: isolateLatin(e.message), ok: false);
      _again();
    } catch (_) {
      if (!mounted || asked != _asked) return;
      _settle(null, words: 'تعذّر التحقق من البطاقة — أعد المسح', ok: false);
      _again();
    }
  }

  /// Not its label: the field emptied and kept, the next press read here.
  void _again() {
    _field.clear();
    widget.focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final tones = AppSemanticColors.of(context);
    final theme = Theme.of(context);
    final tone = _missing ? tones.info : (_ok == true ? tones.ready : tones.blocked);
    final words = _missing ? 'تُطبع للقطعة بطاقة جديدة بعد حفظ المرتجع' : _words;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: TextField(
            key: Key(widget.keyBase),
            controller: _field,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            enabled: !_missing,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: 'بطاقة القطعة ${ltrIsolate(widget.itemCode)}',
              hintText: 'امسحها بالقارئ أو اكتب رقمها',
              prefixIcon: const Icon(Icons.sensors),
              suffixIcon: _asking
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    )
                  : null,
              border: const OutlineInputBorder(),
            ),
            // the reader types a whole value with no Enter reaching the field
            onChanged: (v) {
              if (ReturnLabelField.whole.hasMatch(v.trim())) _check(v);
            },
            onSubmitted: _check,
          ),
        ),
        const SizedBox(width: 8),
        FilterChip(
          key: Key('${widget.keyBase}-missing'),
          label: const Text('البطاقة مفقودة أو تالفة'),
          selected: _missing,
          onSelected: (v) {
            _asked++;
            setState(() {
              _missing = v;
              _field.clear();
              _words = null;
              _ok = null;
              _asking = false;
            });
            widget.onSettled(v ? const ReturnLabel.missing() : null);
          },
        ),
      ]),
      if (words != null) ...[
        const SizedBox(height: 6),
        Row(children: [
          Icon(_missing ? Icons.print_outlined : (_ok == true ? Icons.verified_outlined : Icons.block),
              size: 18, color: tone.fg),
          const SizedBox(width: 6),
          Expanded(
            child: Text(words,
                key: Key('${widget.keyBase}-state'),
                style: theme.textTheme.bodySmall?.copyWith(color: tone.fg)),
          ),
        ]),
      ],
    ]);
  }
}
