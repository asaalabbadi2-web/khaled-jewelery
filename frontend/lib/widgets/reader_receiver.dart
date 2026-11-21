import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import 'reader_capture.dart';

/// «استقبال القارئ» (the owner, 21 Nov 2026: «ما فائدة الحقل إذا كان لا يحمل
/// قيمة؟»): the handheld reader types each tag into the focused text field
/// (its Send mode Focus), and nowhere else -- so a field is the door it comes
/// in by, not a place a value is kept or typed. It is shown as what it is: a
/// panel that says whether the reader is heard -- «القارئ جاهز — اضغط زرّه»
/// while the field is focused, «اضغط هنا ليستقبل القارئ» when it is not --
/// and the last value taken. The field under it is not seen, opens no
/// on-screen keyboard (the reader needs none), and is emptied after each
/// value ([ReaderCapture.clearAfterRead]).
///
/// On the owner's reader the field lost its focus after each value (21 Nov
/// 2026: «يقرأ رمز ثم يفقد التركيز»): the panel takes it back by itself a
/// moment after, while its screen is the one shown -- never from a dialog
/// opened over it -- and Enter ends nothing.
class ReaderReceiver extends StatefulWidget {
  const ReaderReceiver({super.key, required this.capture, required this.focusNode, required this.fieldKey});
  final ReaderCapture capture;
  final FocusNode focusNode;

  /// The hidden field's key -- what a test types into, as the reader does.
  final Key fieldKey;

  @override
  State<ReaderReceiver> createState() => _ReaderReceiverState();
}

class _ReaderReceiverState extends State<ReaderReceiver> {
  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
  }

  @override
  void dispose() {
    widget.focusNode.removeListener(_changed);
    super.dispose();
  }

  /// How long after losing its focus the panel takes it back.
  static const back = Duration(milliseconds: 150);

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (!widget.focusNode.hasFocus) {
      Future<void>.delayed(back, () {
        if (!mounted || widget.focusNode.hasFocus) return;
        if (ModalRoute.of(context)?.isCurrent == false) return;      // a dialog over it keeps its own field
        widget.focusNode.requestFocus();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final heard = widget.focusNode.hasFocus;
    final tone = heard ? tones.ready : tones.warning;
    final last = widget.capture.lastWords;
    return Semantics(
      key: const Key('reader-receiver'),
      label: heard ? 'القارئ جاهز' : 'اضغط هنا ليستقبل القارئ',
      child: Stack(children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: tone.container,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tone.fg),
          ),
          child: Row(children: [
            Icon(heard ? Icons.sensors : Icons.touch_app_outlined, color: tone.onContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  heard ? 'القارئ جاهز — اضغط زرّه' : 'اضغط هنا ليستقبل القارئ',
                  key: const Key('reader-receiver-state'),
                  style: theme.textTheme.titleSmall?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w800),
                ),
                if (last != null)
                  Text(
                    last,
                    key: const Key('reader-receiver-last'),
                    style: theme.textTheme.bodySmall?.copyWith(color: tone.onContainer),
                  ),
              ]),
            ),
          ]),
        ),
        // the door the reader comes in by: a real field, not seen, its taps the panel's
        Positioned.fill(
          child: Opacity(
            opacity: 0,
            child: TextField(
              key: widget.fieldKey,
              controller: widget.capture.field,
              focusNode: widget.focusNode,
              autofocus: true,
              keyboardType: TextInputType.none,
              showCursor: false,
              enableInteractiveSelection: false,
              maxLines: null,
              expands: true,
              decoration: const InputDecoration.collapsed(hintText: null),
              onEditingComplete: () {},                                  // Enter ends nothing
              onChanged: (text) {
                widget.capture.typed(text);
                setState(() {});
              },
            ),
          ),
        ),
      ]),
    );
  }
}
