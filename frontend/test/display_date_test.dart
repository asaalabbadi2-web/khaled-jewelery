import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/display_date.dart';

/// The owner (17 Nov 2026): «اصلح التاريخ والوقت في السندات والفواتير
/// وغيرها». A date was shown three ways (2026-10-08, 2026/10/08,
/// 08/10/2026) and, where its formatter asked for the 'en' locale's data
/// before it was loaded -- a test, an isolate -- as the machine wrote it
/// («2026-10-08T10:00:00», «2026-11-17T08:39:32.432715»). One way now, in
/// Western digits, with no locale to load.
void main() {
  test('a day', () {
    expect(displayDate('2026-10-08T10:00:00'), '2026-10-08');
    expect(displayDate('2026-10-08'), '2026-10-08');
    expect(displayDate(DateTime(2026, 1, 5, 23, 59)), '2026-01-05');
  });

  test('a day and its time, to the minute', () {
    expect(displayDateTime('2026-11-17T08:39:32.432715'), '2026-11-17 08:39');
    expect(displayDateTime(DateTime(2026, 1, 5, 7, 3)), '2026-01-05 07:03');
  });

  test('a moment the server wrote in UTC is read in the shop\'s time', () {
    final utc = DateTime.utc(2026, 11, 17, 8, 39);
    expect(displayDateTime('2026-11-17T08:39:00Z'), displayDateTime(utc.toLocal()));
  });

  test('nothing is a dash; what is not a date is kept as written', () {
    expect(displayDate(null), '—');
    expect(displayDate(''), '—');
    expect(displayDateTime(null, empty: 'غير محدد'), 'غير محدد');
    expect(displayDate('قريبًا'), 'قريبًا');
  });

  test('in an isolate too, where no locale was loaded', () async {
    final out = await Isolate.run(() => displayDateTime('2026-10-08T10:00:00'));
    expect(out, '2026-10-08 10:00');
  });
}
