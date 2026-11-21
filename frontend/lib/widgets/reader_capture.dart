import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// One thing a handheld reader sent: a value read -- a tag's or a label's
/// printed code -- or its button pressed; its press, and when on the reader.
typedef ReaderEvent = ({String kind, String? value, String gapBefore, int press, int ms});

/// What a handheld reader sends the browser (ADR-085 ت0; seen on the owner's
/// reader, 21 Nov 2026), one reading for «فحص القارئ» and «جرد بالمسح»:
///
/// - each tag it reads typed whole into the focused field, then Enter (its
///   Send mode Focus, its Suffix Enter); a value is a tag's -- 24 characters,
///   «4B4A» first -- or a printed code «KJ-», found wherever it is in what was
///   typed, so a reader that puts nothing between two is read too;
/// - its button as the key F12, repeated every ~50 ms while held.
///
/// Events closer than [pressGap] to the one before -- a read or the button --
/// are one press. Time is a stopwatch from the first event, not the clock:
/// only the gaps are asked.
class ReaderCapture {
  ReaderCapture({required this.onEvents, this.elapsed, int pressesBefore = 0, this.clearAfterRead = false})
      : _press = pressesBefore;

  static final value = RegExp(r'4B4A[0-9A-F]{20}|KJ-\d{6,}');
  static const pressGap = 500;

  final void Function(List<ReaderEvent> events) onEvents;

  /// Milliseconds from the first event -- a stopwatch unless given (a test's).
  final int Function()? elapsed;

  /// The field emptied after each value taken, so it never grows: what follows
  /// the last value kept -- not waiting for Enter, which a one-line field
  /// never takes (the owner, 21 Nov 2026: «الحقل يكدّس الأكواد»).
  final bool clearAfterRead;

  final TextEditingController field = TextEditingController();
  final Stopwatch _since = Stopwatch();
  int _taken = 0;
  int _press;
  int? _lastEvent;
  int? _lastButton;

  /// The presses so far, and the button's own (F12): a key held is one press.
  int get press => _press;
  int buttonPresses = 0;

  /// The last value taken and its press -- said under an emptied field, so the
  /// coder sees what the reader read (the owner, 21 Nov 2026).
  String? lastValue;
  int? lastPress;

  /// «آخر قراءة: … · الضغطة n», or null before the first.
  String? get lastWords => lastValue == null ? null : 'آخر قراءة: $lastValue · الضغطة $lastPress';

  int get _now {
    if (!_since.isRunning) _since.start();
    return elapsed?.call() ?? _since.elapsedMilliseconds;
  }

  int _pressAt(int now) {
    final last = _lastEvent;
    if (last == null || now - last > pressGap) _press++;
    _lastEvent = now;
    return _press;
  }

  void start() => HardwareKeyboard.instance.addHandler(_key);

  void dispose() {
    HardwareKeyboard.instance.removeHandler(_key);
    field.dispose();
  }

  bool _key(KeyEvent event) {
    if (event.logicalKey != LogicalKeyboardKey.f12 || event is KeyUpEvent) return false;
    final now = _now;
    final lastButton = _lastButton;
    _lastButton = now;
    if (lastButton == null || now - lastButton > pressGap) buttonPresses++;
    onEvents([(kind: 'button', value: null, gapBefore: '', press: _pressAt(now), ms: now)]);
    return false;
  }

  /// The field's text as it now is: its new values, each an event.
  void typed(String text) {
    final upper = text.toUpperCase();
    final found = value.allMatches(upper).toList();
    if (found.length <= _taken) return;
    final now = _now;
    final press = _pressAt(now);
    final events = <ReaderEvent>[
      for (var i = _taken; i < found.length; i++)
        (
          kind: 'read',
          value: found[i].group(0)!,
          gapBefore: i > 0 ? upper.substring(found[i - 1].end, found[i].start) : '',
          press: press,
          ms: now,
        ),
    ];
    _taken = found.length;
    lastValue = events.last.value;
    lastPress = press;
    if (clearAfterRead) {
      final rest = upper.substring(found.last.end).replaceFirst(RegExp(r'^\s+'), '');
      field.value = TextEditingValue(text: rest, selection: TextSelection.collapsed(offset: rest.length));
      _taken = 0;
    }
    onEvents(events);
  }

  /// From the start again: no press, no time.
  void reset() {
    field.clear();
    _taken = 0;
    _press = 0;
    _lastEvent = null;
    _lastButton = null;
    buttonPresses = 0;
    lastValue = null;
    lastPress = null;
    _since
      ..stop()
      ..reset();
  }
}
