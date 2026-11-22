// The system's tones on a scan, made in the browser -- no sound file to load
// (utils/scan_feedback.dart). A page that was touched once may play them.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

web.AudioContext? _context;

void play(bool added) {
  try {
    final ctx = _context ??= web.AudioContext();
    if (ctx.state == 'suspended') ctx.resume();
    final now = ctx.currentTime;
    if (added) {
      _beep(ctx, now, hz: 1320, seconds: 0.09);
    } else {
      _beep(ctx, now, hz: 440, seconds: 0.14);
      _beep(ctx, now + 0.2, hz: 330, seconds: 0.18);
      web.window.navigator.vibrate([120, 80, 160].map((ms) => ms.toJS).toList().toJS);
    }
  } catch (_) {
    // no audio here: the screen still says it in words
  }
}

void _beep(web.AudioContext ctx, double at, {required double hz, required double seconds}) {
  final osc = ctx.createOscillator()
    ..type = 'sine'
    ..frequency.value = hz;
  final gain = ctx.createGain();
  gain.gain
    ..setValueAtTime(0.0001, at)
    ..exponentialRampToValueAtTime(0.3, at + 0.01)
    ..exponentialRampToValueAtTime(0.0001, at + seconds);
  osc.connect(gain);
  gain.connect(ctx.destination);
  osc.start(at);
  osc.stop(at + seconds + 0.02);
}
