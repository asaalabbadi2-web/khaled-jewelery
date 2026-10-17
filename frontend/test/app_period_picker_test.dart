import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/app_period_picker.dart';

/// UI-4 (ADR-049): the ready periods are whole days, from the first to the
/// last, on any date -- January's last month is December.
void main() {
  DateTimeRange r(DateTime a, DateTime b) => DateTimeRange(start: a, end: b);

  test('each ready period on a mid-month afternoon', () {
    final now = DateTime(2026, 10, 17, 15, 42);
    expect(
      periodRange(AppPeriod.today, now),
      r(DateTime(2026, 10, 17), DateTime(2026, 10, 17)),
    );
    expect(
      periodRange(AppPeriod.thisMonth, now),
      r(DateTime(2026, 10, 1), DateTime(2026, 10, 17)),
    );
    expect(
      periodRange(AppPeriod.lastMonth, now),
      r(DateTime(2026, 9, 1), DateTime(2026, 9, 30)),
    );
    expect(
      periodRange(AppPeriod.thisYear, now),
      r(DateTime(2026, 1, 1), DateTime(2026, 10, 17)),
    );
  });

  test("January's last month is last year's December", () {
    expect(
      periodRange(AppPeriod.lastMonth, DateTime(2027, 1, 5)),
      r(DateTime(2026, 12, 1), DateTime(2026, 12, 31)),
    );
  });

  test('a leap February ends on the 29th', () {
    expect(
      periodRange(AppPeriod.lastMonth, DateTime(2028, 3, 2)),
      r(DateTime(2028, 2, 1), DateTime(2028, 2, 29)),
    );
  });

  test('its label', () {
    expect(periodLabel(null), 'كل الفترات');
    expect(
      periodLabel(r(DateTime(2026, 10, 17), DateTime(2026, 10, 17))),
      '17/10/2026',
    );
    expect(
      periodLabel(r(DateTime(2026, 9, 1), DateTime(2026, 9, 30))),
      '01/09/2026 – 30/09/2026',
    );
  });

  testWidgets('a ready period is one tap; «all» clears it', (tester) async {
    final chosen = <DateTimeRange?>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(
            body: Center(
              child: AppPeriodPicker(
                range: null,
                now: () => DateTime(2026, 10, 17),
                onChanged: chosen.add,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('كل الفترات'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('الشهر الماضي'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(AppPeriodPicker));
    await tester.pumpAndSettle();
    await tester.tap(find.text('كل الفترات').last);
    await tester.pumpAndSettle();
    expect(chosen, [r(DateTime(2026, 9, 1), DateTime(2026, 9, 30)), null]);
  });
}
