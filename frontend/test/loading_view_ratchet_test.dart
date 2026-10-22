import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// A screen's first load is the app's skeleton (`AppLoadingView`), not a
/// spinner in the middle of the page (ADR-057 ر١). The safes screen and the
/// voucher's details kept their spinner after their reviews, for nothing held
/// them to it.
///
/// Counted: a `Center` whose child is a `CircularProgressIndicator`, written
/// on one line or over several. A spinner in a button, or in a dialog shown
/// while an action runs, is not this -- the dialogs that are (the invoices
/// list's three, the journal list's one) sit in the baseline
/// (`test/loading_view_baseline.json`). The count goes down, never up.
///
/// After a screen takes the skeleton its limit is lowered:
///   UPDATE_LOADING_VIEW_BASELINE=1 flutter test test/loading_view_ratchet_test.dart
class _CenteredSpinnerRatchet extends SourceRatchet {
  _CenteredSpinnerRatchet()
    : super(
        pattern: _centeredSpinner,
        baselinePath: 'test/loading_view_baseline.json',
        updateEnv: 'UPDATE_LOADING_VIEW_BASELINE',
      );

  /// Over the whole text, the `//` lines left out: the spinner is often a
  /// line below its `Center(`.
  @override
  int countIn(String text) => pattern
      .allMatches(
        text
            .split('\n')
            .where((line) => !line.trimLeft().startsWith('//'))
            .join('\n'),
      )
      .length;
}

final _centeredSpinner = RegExp(
  r'Center\(\s*child:\s*(?:const\s+)?CircularProgressIndicator\(',
);

final ratchet = _CenteredSpinnerRatchet();

void main() {
  test('what counts as a spinner in the middle of a page', () {
    int n(String s) => ratchet.countIn(s);
    expect(n('return const Center(child: CircularProgressIndicator());'), 1);
    expect(
      n('return Center(\n  child: CircularProgressIndicator(color: c),\n);'),
      1,
    );
    expect(n('SizedBox(width: 18, child: CircularProgressIndicator())'), 0);
    expect(n('// Center(child: CircularProgressIndicator())'), 0);
    expect(n('return const AppLoadingView();'), 0);
  });

  test('no file gains a spinner in the middle of a page', () {
    expect(
      ratchet.grown(),
      isEmpty,
      reason:
          'دائرة تحميل في منتصف الصفحة زادت. حمّل الشاشة بـAppLoadingView '
          '(lib/widgets/app_state_views.dart).',
    );
  });
}
