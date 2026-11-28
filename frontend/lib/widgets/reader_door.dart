import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// The rule a reader's door keeps the focus by -- «استقبال القارئ»'s (the owner, 21-22 Nov 2026), one
/// rule for [ReaderReceiver] and [ScanField] alike (26 Nov 2026: «لا نبني منطق تركيز جديدًا»):
///
/// - the handheld reader types into the focused field and nowhere else, so the door takes the focus
///   when **nothing holds it** -- after a value, when the reader's own Enter left it (21 Nov 2026:
///   «يقرأ رمز ثم يفقد التركيز»); after a touch on the screen's blank (22 Nov 2026: «بمجرد لمس الشاشة
///   وضياع التركيز ... صوت قراءة ولا يوجد قراءة»); when a dialog or a page over it closes and nothing
///   took the focus back;
/// - **it never takes it from what holds it** (the owner, 28 Nov 2026: «لا تقبل نقل التركيز الى مكان
///   اخر» -- the door took it back 150 ms after it left, from anything but a text field: Tab could not
///   pass it, a box or a dropdown lost it): a text field, a button, a box, a dropdown, a menu's item --
///   whatever the user or the keyboard gave it to. Then the door says it is not heard
///   ([ReaderReceiver]: «اضغط هنا ليستقبل القارئ») and a touch on it is the way back;
/// - what holds the focus ([holdsFocus]): a node, not a scope -- a screen's shortcuts wrapper
///   (AppDocumentShortcuts) is a scope, and a scope alone is nothing held -- that may be focused and
///   is in the traversal; nothing, the root, or a scope with nothing in it, holds it not;
/// - read once the move is over -- at the end of its frame -- never as a leave to take: one look a
///   frame, whatever the moves within it; none while the screen is under a dialog or a page;
/// - one door a screen holds it -- two would take it from each other; said at once in a debug build,
///   where the tests run.
///
/// The door that does not hold the focus ([doorHoldsFocus] false) still hears the reader while it
/// is focused; it takes nothing.
mixin ReaderDoorFocus<T extends StatefulWidget> on State<T> {
  /// The door's own node.
  FocusNode get doorNode;

  /// Whether this door takes the focus when nothing holds it.
  bool get doorHoldsFocus;

  /// The door's focus came or went -- what a door shows of it.
  void doorFocusChanged() {}

  static final Map<ModalRoute<dynamic>, Set<State>> _holders = {};
  static final Set<ModalRoute<dynamic>> _checking = {};
  ModalRoute<dynamic>? _route;

  /// One look at the end of a frame, however many moves came in it.
  bool _looking = false;

  /// Whether [node] holds the focus: a node the user or the keyboard may be on -- not a scope (a
  /// screen's shortcuts wrapper is one), focusable, in the traversal.
  static bool holdsFocus(FocusNode? node) =>
      node != null && node is! FocusScopeNode && node.canRequestFocus && !node.skipTraversal && node.context != null;

  @override
  void initState() {
    super.initState();
    doorNode.addListener(_changed);
    FocusManager.instance.addListener(_lookSoon);
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
    FocusManager.instance.removeListener(_lookSoon);
    final holders = _holders[_route];
    holders?.remove(this);
    if (holders != null && holders.isEmpty) _holders.remove(_route);
    super.dispose();
  }

  void _changed() {
    if (!mounted) return;
    doorFocusChanged();
  }

  /// The focus moved: looked at once it is over -- at the end of the frame, one look a frame.
  void _lookSoon() {
    if (_looking || !mounted || !doorHoldsFocus || doorNode.hasFocus) return;
    _looking = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _looking = false;
      _look();
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  /// The door takes the focus only when nothing holds it, its screen the one shown.
  void _look() {
    if (!mounted || !doorHoldsFocus || doorNode.hasFocus) return;
    if (ModalRoute.of(context)?.isCurrent == false) return; // a dialog or a page over it: theirs
    if (holdsFocus(FocusManager.instance.primaryFocus)) return; // given to something: kept there
    doorNode.requestFocus();
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
