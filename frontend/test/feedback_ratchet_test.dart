import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// UI-1 (ADR-049): the user is told how an action went through
/// `AppFeedback` (`lib/widgets/app_feedback.dart`), in the user's words.
///
/// Two counts per file that may go down and never up; a new file's is zero
/// (`test/feedback_*_baseline.json`). After a screen is moved:
///   UPDATE_FEEDBACK_BASELINE=1 flutter test test/feedback_ratchet_test.dart
final snackBars = SourceRatchet(
  pattern: RegExp(r'\.showSnackBar\('),
  baselinePath: 'test/feedback_snackbar_baseline.json',
  updateEnv: 'UPDATE_FEEDBACK_BASELINE',
  skipDirs: const ['lib/widgets/app_feedback.dart'],
);

/// An exception written into a text: `'خطأ: $e'`, `'${e.toString()}'`. On
/// screen it reads «Exception: ...»; a log line may say it.
final exceptionTexts = SourceRatchet(
  pattern: RegExp(
    r'\$(e|err|error)\b(?!\.)|\$\{(e|err|error)(\.toString\(\))?\}',
  ),
  baselinePath: 'test/feedback_exception_text_baseline.json',
  updateEnv: 'UPDATE_FEEDBACK_BASELINE',
  skipDirs: const ['lib/widgets/app_feedback.dart'],
  ignoreLine: RegExp(r'debugPrint\(|\bprint\(|\blog\('),
);

void main() {
  test('what counts', () {
    expect(snackBars.countIn('ScaffoldMessenger.of(context).showSnackBar('), 1);
    expect(snackBars.countIn('AppFeedback.error(context, e)'), 0);

    int n(String s) => exceptionTexts.countIn(s);
    expect(n("Text('خطأ: \$e')"), 1);
    expect(n("Text('فشل الحفظ: \${e.toString()}')"), 1);
    expect(n("_showError('\$error')"), 1);
    expect(n("Text('\$errorMessage')"), 0);
    expect(n("debugPrint('خطأ: \$e')"), 0);
    expect(n('AppFeedback.error(context, e)'), 0);
  });

  test('no file gains a snackbar of its own', () {
    expect(
      snackBars.grown(),
      isEmpty,
      reason:
          'رسالة منبثقة جديدة خارج AppFeedback. استعمل '
          'AppFeedback.success/info/error(context, ...).',
    );
  });

  test('no file gains an exception written into a text', () {
    expect(
      exceptionTexts.grown(),
      isEmpty,
      reason:
          "نصّ استثناء جديد في نصّ يُعرض ('خطأ: \$e'). استعمل "
          'AppFeedback.error(context, e) أو AppFeedback.messageOf(e).',
    );
  });
}
