/// How a date is shown: one way, everywhere -- 2026-10-08, and 2026-10-08
/// 14:30 with its time (the owner, 17 Nov 2026: «اصلح التاريخ والوقت في
/// السندات والفواتير وغيرها»).
///
/// Written by hand, not by DateFormat: a formatter that asks for a locale's
/// data ('en') before it is loaded -- in an isolate, in a test -- throws, and
/// the screens' fallback showed the machine's text («2026-10-08T10:00:00»).
/// Western digits always, beside Arabic text and in print.
library;

DateTime? _moment(Object? value) {
  if (value is DateTime) return value.isUtc ? value.toLocal() : value;
  final text = (value ?? '').toString().trim();
  if (text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  return parsed == null ? null : (parsed.isUtc ? parsed.toLocal() : parsed);
}

String _two(int n) => n.toString().padLeft(2, '0');

String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${_two(d.month)}-${_two(d.day)}';

/// [value] -- a DateTime or the server's text -- as its day; [empty] when
/// there is none, and text that is no date as it was written.
String displayDate(Object? value, {String empty = '—'}) {
  final d = _moment(value);
  if (d != null) return _day(d);
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? empty : text;
}

/// [value] as its day and its time, to the minute.
String displayDateTime(Object? value, {String empty = '—'}) {
  final d = _moment(value);
  if (d != null) return '${_day(d)} ${_two(d.hour)}:${_two(d.minute)}';
  final text = (value ?? '').toString().trim();
  return text.isEmpty ? empty : text;
}
