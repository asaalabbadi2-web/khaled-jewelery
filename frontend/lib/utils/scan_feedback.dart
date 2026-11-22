import '../src/scan_tone_stub.dart' if (dart.library.html) '../src/scan_tone_web.dart' as tone;

/// The system's own word on a scan (the owner, 22 Nov 2026: «الصوت الصادر من
/// القارئ يوهمنا أن القطعة مضافة وهو لم يضفها»). The handheld reader beeps
/// when it decodes a code, whether the page took it or not; a page cannot
/// silence it. So the system says what it did: a short high tone when the
/// piece went in, two low ones and a buzz when it was refused -- and the
/// reader's own beep is turned off in its scanner's settings, leaving the
/// system's alone.
class ScanFeedback {
  ScanFeedback._();

  /// What plays it -- the browser's audio and vibration on the web, nothing
  /// elsewhere; a test puts its own to hear what was said.
  static void Function(bool added) say = tone.play;

  static void added() => say(true);
  static void refused() => say(false);
}
