import 'dart:async';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../api_service.dart';
import '../theme/app_semantic_colors.dart';

/// UI-1 (ADR-049): the one way the app tells the user how an action went.
///
/// A screen says `AppFeedback.success(context, 'حُفظ السند')` or
/// `AppFeedback.error(context, e)` and does not build its own SnackBar: one
/// look, one duration, colors from the theme in both modes, and an error said
/// in the user's words -- the server's message for a refusal, a sentence for
/// a lost network -- never «Exception: ...».
abstract final class AppFeedback {
  static const networkMessage =
      'تعذّر الوصول إلى الخادم. تحقّق من الشبكة ثم أعد المحاولة.';
  static const timeoutMessage = 'انتهت مهلة الاتصال بالخادم. أعد المحاولة.';
  static const unreadableMessage =
      'وصل من الخادم ردّ غير مفهوم. أعد المحاولة، وإن تكرر فأبلغ الدعم.';

  /// What [error] says to the user.
  ///
  /// [error] may be the exception itself or a text a screen already composed
  /// around it (`'فشل حفظ الفاتورة: $e'`); the screen's own words are kept and
  /// only the exception's are replaced.
  static String messageOf(Object error) {
    if (error is ApiException) return error.message;
    if (error is ApiAuthException) return error.message;
    if (error is LoginRefused) return error.message;
    if (error is TimeoutException) return timeoutMessage;
    if (error is http.ClientException) return networkMessage;
    if (error is FormatException) return unreadableMessage;
    return _clean(error.toString());
  }

  static final _network = RegExp(
    r'ClientException|SocketException|XMLHttpRequest error|Failed to fetch|'
    r'Connection (refused|reset|closed)',
  );
  static final _timeout = RegExp(r'TimeoutException');
  static final _exceptionWord = RegExp(r'(?<![A-Za-z])Exception: ?');

  static String _clean(String text) {
    for (final (signature, sentence) in [
      (_network, networkMessage),
      (_timeout, timeoutMessage),
    ]) {
      final m = signature.firstMatch(text);
      if (m != null) {
        final said = text.substring(0, m.start).replaceAll(_exceptionWord, '');
        return '$said$sentence'.trim();
      }
    }
    return text.replaceAll(_exceptionWord, '').trim();
  }

  /// [action]: at most one thing to do from the message (e.g. «معاينة»).
  static void success(
    BuildContext context,
    String message, {
    FeedbackAction? action,
  }) => _show(context, _Kind.success, message, action: action);

  static void info(
    BuildContext context,
    String message, {
    FeedbackAction? action,
  }) => _show(context, _Kind.info, message, action: action);

  /// [error] is an exception or a text; [title] a short heading above it.
  static void error(BuildContext context, Object error, {String? title}) =>
      _show(context, _Kind.error, messageOf(error), title: title);

  static void _show(
    BuildContext context,
    _Kind kind,
    String message, {
    String? title,
    FeedbackAction? action,
  }) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    final cs = Theme.of(context).colorScheme;
    final tone = AppSemanticColors.of(context);
    final (
      Color background,
      Color foreground,
      IconData icon,
      Duration shown,
    ) = switch (kind) {
      _Kind.success => (
        tone.ready.container,
        tone.ready.onContainer,
        Icons.check_circle_outline,
        const Duration(seconds: 3),
      ),
      _Kind.info => (
        tone.info.container,
        tone.info.onContainer,
        Icons.info_outline,
        const Duration(seconds: 4),
      ),
      _Kind.error => (
        cs.errorContainer,
        cs.onErrorContainer,
        Icons.error_outline,
        const Duration(seconds: 8),
      ),
    };
    final text = Theme.of(
      context,
    ).textTheme.bodyLarge?.copyWith(color: foreground);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: background,
          behavior: SnackBarBehavior.floating,
          width: wide ? 560 : null,
          duration: shown,
          showCloseIcon: kind == _Kind.error,
          closeIconColor: foreground,
          action: action == null
              ? null
              : SnackBarAction(
                  label: action.label,
                  textColor: foreground,
                  onPressed: action.onPressed,
                ),
          content: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, color: foreground),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (title != null)
                      Text(
                        title,
                        style: text?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    Text(message, style: text),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
  }
}

enum _Kind { success, info, error }

/// The one thing a message offers to do.
typedef FeedbackAction = ({String label, VoidCallback onPressed});
