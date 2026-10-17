import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat;

/// UI-4 (ADR-049): one control for a list's period -- the ready ones a tap
/// away, a range from the calendar, or all. Taken from the statement's own
/// (its test: «a ready period sets the range in one tap»); the vouchers list
/// had a bare «من - إلى» and no ready period.

/// The ready periods.
enum AppPeriod {
  today('اليوم'),
  thisMonth('هذا الشهر'),
  lastMonth('الشهر الماضي'),
  thisYear('هذه السنة');

  const AppPeriod(this.label);
  final String label;
}

/// The days [period] covers on [now]'s date: whole days, from its first to its
/// last (today for one still running).
DateTimeRange periodRange(AppPeriod period, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  return switch (period) {
    AppPeriod.today => DateTimeRange(start: today, end: today),
    AppPeriod.thisMonth => DateTimeRange(
      start: DateTime(now.year, now.month, 1),
      end: today,
    ),
    AppPeriod.lastMonth => DateTimeRange(
      start: DateTime(now.year, now.month - 1, 1),
      end: DateTime(now.year, now.month, 0),
    ),
    AppPeriod.thisYear => DateTimeRange(
      start: DateTime(now.year, 1, 1),
      end: today,
    ),
  };
}

/// What a period reads on its button: «كل الفترات», a day, or «from – to».
String periodLabel(DateTimeRange? range, {String all = 'كل الفترات'}) {
  if (range == null) return all;
  final f = DateFormat('dd/MM/yyyy');
  return range.start == range.end
      ? f.format(range.start)
      : '${f.format(range.start)} – ${f.format(range.end)}';
}

/// The button: shows [range] (null is all), and gives the one chosen to
/// [onChanged] -- a ready period, a range from the calendar, or null for all.
class AppPeriodPicker extends StatelessWidget {
  const AppPeriodPicker({
    super.key,
    required this.range,
    required this.onChanged,
    this.now,
  });

  final DateTimeRange? range;
  final ValueChanged<DateTimeRange?> onChanged;

  /// Today, for tests; the device's clock otherwise.
  final DateTime Function()? now;

  Future<void> _pickRange(BuildContext context) async {
    final today = (now ?? DateTime.now)();
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange:
          range ??
          DateTimeRange(
            start: today.subtract(const Duration(days: 30)),
            end: today,
          ),
      firstDate: DateTime(today.year - 5),
      lastDate: DateTime(today.year + 1, 12, 31),
      saveText: 'تطبيق',
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'الفترة',
      onSelected: (key) {
        switch (key) {
          case 'custom':
            _pickRange(context);
          case 'all':
            onChanged(null);
          default:
            onChanged(
              periodRange(
                AppPeriod.values.byName(key),
                (now ?? DateTime.now)(),
              ),
            );
        }
      },
      itemBuilder: (_) => [
        for (final p in AppPeriod.values)
          PopupMenuItem(value: p.name, child: Text(p.label)),
        const PopupMenuDivider(),
        const PopupMenuItem(value: 'custom', child: Text('نطاق مخصص…')),
        const PopupMenuItem(value: 'all', child: Text('كل الفترات')),
      ],
      child: IgnorePointer(
        child: OutlinedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.event_note, size: 18),
          label: Text(periodLabel(range), overflow: TextOverflow.ellipsis),
        ),
      ),
    );
  }
}
