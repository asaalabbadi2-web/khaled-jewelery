import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import 'reader_capture.dart';
import 'reader_door.dart';

/// What a screen says of a value taken: done, or refused, in its words.
typedef ScanSaid = ({bool ok, String words});

/// «امسح القطعة» -- a field the handheld reader types into, beside the screen's other fields (the
/// owner, 26 Nov 2026: «خلل في الضغط والتمرير ويظهر خصوصًا في الشاشات الصغيرة»). Four such fields were
/// built each its own way: each opened the on-screen keyboard, took the focus back after each answer
/// from wherever the user was, and pulled the screen to itself. One field now, on what «استقبال
/// القارئ» already is:
///
/// - **read**: no on-screen keyboard ([TextInputType.none]; on the web `inputmode="none"`, which the
///   owner's reader opened none with). A value is what [ReaderCapture] says one is -- a tag whole at
///   its 24th character, a printed number once the reader is quiet -- taken with no Enter, the field
///   emptied, the same value held on one label taken once;
/// - **its focus**: [ReaderDoorFocus], the receiver's rule -- taken back only when nothing holds it,
///   never from a field the user chose or a dialog; one door a screen ([holdsFocus]);
/// - **the screen stays put** ([StayPut]): taking the focus or being typed into never scrolls it;
/// - **typed by hand** (a label worn away): «⌨» opens the keyboard, nothing is taken while it is typed,
///   «✓» or Enter takes it once, and the field is the reader's again, the keyboard closed;
/// - **its words**: what [onValue] said of the last value, under it. A character typed rebuilds
///   nothing of the screen: the screen hears a value whole, once.
class ScanField extends StatefulWidget {
  const ScanField({
    super.key,
    required this.keyBase,
    required this.label,
    required this.onValue,
    this.hint,
    this.holdsFocus = true,
    this.enabled = true,
  });

  /// The field is `keyBase`; its words `keyBase-state`, its keyboard `keyBase-keyboard`, its «✓» `keyBase-take`.
  final String keyBase;
  final String label;
  final String? hint;

  /// A value whole -- [typed] false: the reader's, a tag or a printed number; true: written by hand,
  /// as written (the server reads «1» as KJ-000001). Asked one at a time, in the order they came.
  final Future<ScanSaid?> Function(String value, {required bool typed}) onValue;

  /// The screen's door: it takes the focus back. One a screen.
  final bool holdsFocus;
  final bool enabled;

  @override
  State<ScanField> createState() => _ScanFieldState();
}

class _ScanFieldState extends State<ScanField> with AutomaticKeepAliveClientMixin, ReaderDoorFocus<ScanField> {
  final _node = FocusNode();
  late final ReaderCapture _capture = ReaderCapture(onEvents: _took, clearAfterRead: true);

  @override
  bool get wantKeepAlive => true;

  @override
  FocusNode get doorNode => _node;

  @override
  bool get doorHoldsFocus => widget.holdsFocus && widget.enabled;

  bool _typing = false;
  bool _reopening = false;
  ScanSaid? _said;
  bool _busy = false;
  final _queue = <(String, bool)>[];

  /// The value just taken: held on one label, the reader sends it again and again -- taken once.
  String? _justTaken;
  Timer? _justTakenFor;

  /// Left in the field after the reader is quiet: a chip that is not ours is said, not asked.
  Timer? _leftover;

  @override
  void dispose() {
    _justTakenFor?.cancel();
    _leftover?.cancel();
    _capture.dispose();
    _node.dispose();
    super.dispose();
  }

  @override
  void doorFocusChanged() {
    // left while typing -- a touch elsewhere -- it is the reader's again; what was typed stays
    if (!_node.hasFocus && _typing && !_reopening) setState(() => _typing = false);
  }

  void _took(List<ReaderEvent> events) {
    for (final e in events) {
      final value = e.value;
      if (e.kind != 'read' || value == null) continue;
      if (value == _justTaken) continue;
      _justTaken = value;
      _justTakenFor?.cancel();
      _justTakenFor = Timer(const Duration(milliseconds: ReaderCapture.pressGap), () => _justTaken = null);
      _ask(value, typed: false);
    }
  }

  void _ask(String value, {required bool typed}) {
    _queue.add((value, typed));
    if (!_busy) _drain();
  }

  Future<void> _drain() async {
    setState(() => _busy = true);
    while (_queue.isNotEmpty) {
      final (value, typed) = _queue.removeAt(0);
      ScanSaid? said;
      try {
        said = await widget.onValue(value, typed: typed);
      } catch (_) {
        said = (ok: false, words: 'تعذّر التحقق — أعد المسح');
      }
      if (!mounted) return;
      if (said != null) setState(() => _said = said);
    }
    if (mounted) setState(() => _busy = false);
  }

  void _changed(String text) {
    if (_typing) return;
    _capture.typed(text);
    _leftover?.cancel();
    _leftover = Timer(const Duration(milliseconds: 300), _sayLeftover);
  }

  void _sayLeftover() {
    if (!mounted || _typing) return;
    final left = _capture.field.text.trim();
    if (ReaderCapture.isTagShaped(left) && !ReaderCapture.isTag(left)) {
      _capture.field.clear();
      setState(() => _said = (ok: false, words: 'قراءة ليست لبطاقة من بطاقاتنا'));
    }
  }

  /// Enter: typed by hand, taken; from the reader, what it sent is whole.
  void _submitted(String _) {
    if (_typing) return _takeTyped();
    _capture.settle();
    final left = _capture.field.text.trim();
    if (left.isEmpty) return;
    _capture.field.clear();
    _ask(left, typed: true);
  }

  void _takeTyped() {
    final text = _capture.field.text.trim();
    if (text.isEmpty) return;
    _capture.field.clear();
    _setTyping(false);
    _ask(text, typed: true);
  }

  /// The keyboard asked for or put away: the field opened again with it, so the platform hears it --
  /// on the web a field's `inputmode="none"` is not taken off while it is open.
  void _setTyping(bool typing) {
    _reopening = true;
    setState(() => _typing = typing);
    _node.unfocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _node.requestFocus();
      _reopening = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final said = _said;
    final tone = said == null ? null : (said.ok ? tones.ready : tones.blocked);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        StayPut(
          active: !_typing,
          child: TextField(
            key: Key(widget.keyBase),
            controller: _capture.field,
            focusNode: _node,
            enabled: widget.enabled,
            autofocus: doorHoldsFocus,
            keyboardType: _typing ? TextInputType.text : TextInputType.none,
            autocorrect: false,
            enableSuggestions: false,
            textDirection: TextDirection.ltr,
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: _typing ? 'اكتب رقم القطعة ثم ✓' : (widget.hint ?? 'امسح بالقارئ'),
              prefixIcon: Icon(_typing ? Icons.keyboard_outlined : Icons.sensors),
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_busy)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 8),
                      child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  if (_typing)
                    IconButton(
                      key: Key('${widget.keyBase}-take'),
                      tooltip: 'اعتماد الرقم',
                      icon: const Icon(Icons.check),
                      onPressed: widget.enabled ? _takeTyped : null,
                    ),
                  IconButton(
                    key: Key('${widget.keyBase}-keyboard'),
                    tooltip: _typing ? 'العودة إلى القارئ' : 'كتابة الرقم يدويًا',
                    icon: Icon(_typing ? Icons.sensors : Icons.keyboard_outlined),
                    onPressed: widget.enabled ? () => _setTyping(!_typing) : null,
                  ),
                ],
              ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: _changed,
            onSubmitted: _submitted,
            onEditingComplete: () {}, // Enter keeps the focus
          ),
        ),
        // its words' line kept from the start: the first value read moves nothing under it
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 20),
            child: said == null
                ? const SizedBox.shrink()
                : Row(children: [
                    Icon(said.ok ? Icons.check_circle_outline : Icons.block, size: 18, color: tone!.fg),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        said.words,
                        key: Key('${widget.keyBase}-state'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(color: tone.fg),
                      ),
                    ),
                  ]),
          ),
        ),
      ],
    );
  }
}
