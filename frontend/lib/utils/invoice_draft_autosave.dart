import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// An invoice being written is kept on the device as it is written (the
/// owner, 9 Nov 2026) -- not only when «إكمال لاحقاً» was pressed. On an
/// iPhone or an iPad the system closes a page in the background without
/// asking (a call, another app, the battery): what was typed was lost unless
/// the button had been pressed. Now it is kept every few seconds while it
/// changes, and at once when the app leaves the screen; the screen offers
/// «استعادة» when it opens again, as it did.
///
/// The screen says what is kept ([buildDraft]), under which key
/// ([draftKey]), and when it may be ([draftKeepable]: a new invoice, its
/// restore question answered, something written, no save in flight).
mixin InvoiceDraftAutosave<T extends StatefulWidget> on State<T> {
  static const interval = Duration(seconds: 3);

  Timer? _draftTimer;
  _OnPause? _observer;
  String? _draftWritten;

  String get draftKey;
  bool get draftKeepable;
  Map<String, dynamic> buildDraft();

  void startDraftAutosave() {
    _observer = _OnPause(keepDraftNow);
    WidgetsBinding.instance.addObserver(_observer!);
    _draftTimer = Timer.periodic(interval, (_) => keepDraftNow());
  }

  /// Kept now, when it may be and has changed since it was last kept.
  Future<void> keepDraftNow() async {
    if (!mounted || !draftKeepable) return;
    final raw = jsonEncode(buildDraft());
    if (raw == _draftWritten) return;
    _draftWritten = raw;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(draftKey, raw);
  }

  /// The draft forgotten -- saved, discarded or declined: it is not written
  /// again until the invoice changes.
  Future<void> forgetDraft() async {
    _draftWritten = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(draftKey);
  }

  void stopDraftAutosave() {
    _draftTimer?.cancel();
    _draftTimer = null;
    if (_observer != null) WidgetsBinding.instance.removeObserver(_observer!);
    _observer = null;
  }
}

class _OnPause extends WidgetsBindingObserver {
  _OnPause(this.keep);
  final Future<void> Function() keep;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      keep();
    }
  }
}
