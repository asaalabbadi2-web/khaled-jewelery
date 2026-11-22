import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

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
///
/// Beside other fields -- the sale invoice's (the owner, 22 Nov 2026: «بمجرد
/// لمس الشاشة وضياع التركيز ... صوت قراءة ولا يوجد قراءة») -- it takes it back
/// whenever nothing holds the focus, a touch on the screen's blank among
/// them, and never from a field the user is typing in.
///
/// And it never moves the screen (the owner, 22 Nov 2026: «لا يمكنك التمرير
/// للأسفل»): a field taking the focus asks to be scrolled into view, and the
/// panel taking it back pulled the screen up to itself after every touch --
/// that request stops at the panel. Scrolled out of sight in a long list it
/// stays alive, so the reader is still heard down the page.
///
/// Its colour says what lasts (the owner, 22 Nov 2026: «تنتقل من الأخضر إلى
/// البرتقالي باستمرار»): the focus lost for a moment and taken back is not
/// shown -- «not heard» only when it stays so [unheardAfter].
///
/// [compact]: one icon, for a screen where the reader is not the matter --
/// the sale invoice's bar (the owner: «رمز القارئ في الزاوية العلوية اليسرى
/// يكفي»); the whole panel where it is -- «جرد بالمسح», «تحقّق من بطاقة».
class ReaderReceiver extends StatefulWidget {
  const ReaderReceiver({
    super.key,
    required this.capture,
    required this.focusNode,
    required this.fieldKey,
    this.compact = false,
  });
  final ReaderCapture capture;
  final FocusNode focusNode;
  final bool compact;

  /// The hidden field's key -- what a test types into, as the reader does.
  final Key fieldKey;

  @override
  State<ReaderReceiver> createState() => _ReaderReceiverState();
}

class _ReaderReceiverState extends State<ReaderReceiver> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  /// What the panel shows: heard, unless unheard for [unheardAfter].
  bool _heard = true;
  Timer? _unheard;

  @override
  void initState() {
    super.initState();
    widget.focusNode.addListener(_changed);
    FocusManager.instance.addListener(_anyChanged);
  }

  @override
  void dispose() {
    _unheard?.cancel();
    widget.focusNode.removeListener(_changed);
    FocusManager.instance.removeListener(_anyChanged);
    super.dispose();
  }

  /// How long after losing its focus the panel takes it back.
  static const back = Duration(milliseconds: 150);

  /// How long unheard before it is shown so.
  static const unheardAfter = Duration(seconds: 1);

  void _changed() {
    if (!mounted) return;
    if (widget.focusNode.hasFocus) {
      _unheard?.cancel();
      if (!_heard) setState(() => _heard = true);
      return;
    }
    _unheard?.cancel();
    _unheard = Timer(unheardAfter, () {
      if (mounted && !widget.focusNode.hasFocus) setState(() => _heard = false);
    });
    _takeBackSoon();
  }

  /// The focus moved anywhere: to nothing, it is the panel's again.
  void _anyChanged() {
    if (!mounted || widget.focusNode.hasFocus) return;
    _takeBackSoon();
  }

  void _takeBackSoon() {
    Future<void>.delayed(back, () {
      if (!mounted || widget.focusNode.hasFocus) return;
      if (ModalRoute.of(context)?.isCurrent == false) return; // a dialog over it keeps its own field
      if (_typingElsewhere()) return; // a field the user chose keeps it
      widget.focusNode.requestFocus();
    });
  }

  static bool _typingElsewhere() {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null && focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// The door the reader comes in by: a real field, not seen, its taps the panel's.
  Widget _door() => _StayPut(
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
        onEditingComplete: () {}, // Enter ends nothing
        onChanged: (text) {
          widget.capture.typed(text);
          setState(() {});
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final heard = _heard;
    final tone = heard ? tones.ready : tones.warning;
    final last = widget.capture.lastWords;
    final door = _door();
    if (widget.compact) {
      return Semantics(
        key: const Key('reader-receiver'),
        label: heard ? 'القارئ جاهز' : 'اضغط هنا ليستقبل القارئ',
        child: Tooltip(
          message: heard ? 'القارئ جاهز' : 'اضغط هنا ليستقبل القارئ',
          child: SizedBox(
            width: 44,
            height: 44,
            child: Stack(
              alignment: Alignment.center,
              children: [
                // the reader's mark on no fill -- not one of the card's filled buttons (the owner,
                // 22 Nov 2026) -- and a small dot its state
                Icon(
                  heard ? Icons.sensors : Icons.sensors_off,
                  key: const Key('reader-receiver-state'),
                  size: 24,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                PositionedDirectional(
                  end: 8,
                  bottom: 8,
                  child: Container(
                    key: const Key('reader-receiver-dot'),
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: tone.fg,
                      shape: BoxShape.circle,
                      border: Border.all(color: theme.colorScheme.surface, width: 1.5),
                    ),
                  ),
                ),
                Positioned.fill(child: door),
              ],
            ),
          ),
        ),
      );
    }
    return Semantics(
      key: const Key('reader-receiver'),
      label: heard ? 'القارئ جاهز' : 'اضغط هنا ليستقبل القارئ',
      child: Stack(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: tone.container,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tone.fg),
            ),
            child: Row(
              children: [
                Icon(heard ? Icons.sensors : Icons.touch_app_outlined, color: tone.onContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        heard ? 'القارئ جاهز — اضغط زرّه' : 'اضغط هنا ليستقبل القارئ',
                        key: const Key('reader-receiver-state'),
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: tone.onContainer,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      if (last != null)
                        Text(
                          last,
                          key: const Key('reader-receiver-last'),
                          style: theme.textTheme.bodySmall?.copyWith(color: tone.onContainer),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          // the door the reader comes in by: a real field, not seen, its taps the panel's
          Positioned.fill(child: door),
        ],
      ),
    );
  }
}

/// Its field's «show me» stops here: the panel never scrolls the screen to itself.
class _StayPut extends SingleChildRenderObjectWidget {
  const _StayPut({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderStayPut();
}

class _RenderStayPut extends RenderProxyBox {
  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {}
}
