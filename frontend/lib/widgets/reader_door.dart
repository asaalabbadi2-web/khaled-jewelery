import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The rule a reader's door keeps the focus by -- «استقبال القارئ»'s (the owner, 21-22 Nov 2026), now
/// one rule for [ReaderReceiver] and [ScanField] alike (the owner, 26 Nov 2026: «لا نبني منطق تركيز
/// جديدًا»):
///
/// - the handheld reader types into the focused field and nowhere else, so a door that loses the
///   focus takes it back by itself a moment after ([back]) -- on the owner's reader it lost it
///   after each value (21 Nov 2026: «يقرأ رمز ثم يفقد التركيز»);
/// - only when nothing holds it: never from a field the user is typing in (22 Nov 2026: in the sale
///   invoice «بمجرد لمس الشاشة وضياع التركيز ... صوت قراءة ولا يوجد قراءة»), and never from a dialog
///   opened over its screen;
/// - one door a screen takes it back -- two would take it from each other with no rule as to which
///   ends with it; said at once in a debug build, where the tests run.
///
/// The door that does not hold the focus ([doorHoldsFocus] false) still hears the reader while it
/// is focused; it takes nothing back.
mixin ReaderDoorFocus<T extends StatefulWidget> on State<T> {
  /// The door's own node.
  FocusNode get doorNode;

  /// Whether this door takes the focus back.
  bool get doorHoldsFocus;

  /// The door's focus came or went -- what a door shows of it.
  void doorFocusChanged() {}

  /// How long after losing its focus the door takes it back.
  static const back = Duration(milliseconds: 150);

  static final Map<ModalRoute<dynamic>, Set<State>> _holders = {};
  static final Set<ModalRoute<dynamic>> _checking = {};
  ModalRoute<dynamic>? _route;

  @override
  void initState() {
    super.initState();
    doorNode.addListener(_changed);
    FocusManager.instance.addListener(_anyChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _claim();
  }

  @override
  void didUpdateWidget(covariant T oldWidget) {
    super.didUpdateWidget(oldWidget);
    _claim();
  }

  void _claim() {
    final route = ModalRoute.of(context);
    if (_route != null && (_route != route || !doorHoldsFocus)) _holders[_route]?.remove(this);
    _route = route;
    if (route == null || !doorHoldsFocus) return;
    _holders.putIfAbsent(route, () => <State>{}).add(this);
    assert(() {
      // checked after the frame, once a route: a door rebuilt under a new key is born before the old one goes
      if (!_checking.add(route)) return true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _checking.remove(route);
        final now = _holders[route]?.where((s) => s.mounted).length ?? 0;
        if (now > 1) {
          FlutterError.reportError(FlutterErrorDetails(
            exception: FlutterError('$now reader doors hold the focus on one screen: one takes it back, '
                'the others are doorHoldsFocus false.'),
            library: 'reader_door',
          ));
        }
      });
      return true;
    }());
  }

  @override
  void dispose() {
    doorNode.removeListener(_changed);
    FocusManager.instance.removeListener(_anyChanged);
    final holders = _holders[_route];
    holders?.remove(this);
    if (holders != null && holders.isEmpty) _holders.remove(_route);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    doorFocusChanged();
    if (!doorNode.hasFocus) _takeBackSoon();
  }

  /// The focus moved anywhere: to nothing, it is the door's again.
  void _anyChanged() {
    if (!mounted || doorNode.hasFocus) return;
    _takeBackSoon();
  }

  void _takeBackSoon() {
    if (!doorHoldsFocus) return;
    Future<void>.delayed(back, () {
      if (!mounted || !doorHoldsFocus || doorNode.hasFocus) return;
      if (ModalRoute.of(context)?.isCurrent == false) return; // a dialog over it keeps its own field
      if (_typingElsewhere()) return; // a field the user chose keeps it
      doorNode.requestFocus();
    });
  }

  static bool _typingElsewhere() {
    final focused = FocusManager.instance.primaryFocus?.context;
    return focused != null && focused.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}

/// A door never moves the screen (the owner, 22 Nov 2026: «لا يمكنك التمرير للأسفل»): a field taking
/// the focus, or typed into, asks to be scrolled into view -- and the door taking it back pulled the
/// screen up to itself after every touch. That request stops here while [active].
class StayPut extends SingleChildRenderObjectWidget {
  const StayPut({super.key, this.active = true, required super.child});

  /// Off while the user types by hand: the field then stays in view above the keyboard.
  final bool active;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderStayPut(active);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderStayPut).active = active;
}

class _RenderStayPut extends RenderProxyBox {
  _RenderStayPut(this.active);
  bool active;

  @override
  void showOnScreen({
    RenderObject? descendant,
    Rect? rect,
    Duration duration = Duration.zero,
    Curve curve = Curves.ease,
  }) {
    if (!active) super.showOnScreen(descendant: descendant, rect: rect, duration: duration, curve: curve);
  }
}
