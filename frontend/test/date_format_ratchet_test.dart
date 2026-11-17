import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// The owner (17 Nov 2026): «اصلح التاريخ والوقت في السندات والفواتير
/// وغيرها». A date is shown through `displayDate` / `displayDateTime`
/// (`lib/utils/display_date.dart`): one way (2026-10-08, 2026-10-08 14:30),
/// Western digits, no locale to load -- not a DateFormat of a screen's own,
/// of which there were three shapes, and those asking for 'en' showed the
/// machine's text where it was not loaded.
///
/// A file's name stamp (yyyyMMdd_HHmmss) is not a date shown and is not
/// counted. The rest may go down in each file and never up; a new file's
/// count is zero (`test/date_format_baseline.json`). After a screen is moved:
///   UPDATE_DATE_FORMAT_BASELINE=1 flutter test test/date_format_ratchet_test.dart
final ratchet = SourceRatchet(
  pattern: RegExp(r'\bDateFormat\('),
  baselinePath: 'test/date_format_baseline.json',
  updateEnv: 'UPDATE_DATE_FORMAT_BASELINE',
  ignoreLine: RegExp(r"DateFormat\('yyyyMMdd"),
);

void main() {
  test('what counts', () {
    int n(String s) => ratchet.countIn(s);
    expect(n("Text(DateFormat('yyyy/MM/dd').format(d))"), 1);
    expect(n("'vouchers_\${DateFormat('yyyyMMdd_HHmmss').format(now)}.xlsx'"), 0);
    expect(n('Text(displayDate(d))'), 0);
  });

  test('no file gains a date format of its own', () {
    expect(
      ratchet.grown(),
      isEmpty,
      reason:
          'تنسيق تاريخ جديد. اعرض التاريخ بـ displayDate(x) أو '
          'displayDateTime(x) من lib/utils/display_date.dart.',
    );
  });
}
