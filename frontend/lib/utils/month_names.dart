/// A Gregorian month by its name (HR-UX ط4: a month was picked as a number).
/// The one table of month names; the year beside it is written as a number.
const _ar = [
  'يناير',
  'فبراير',
  'مارس',
  'أبريل',
  'مايو',
  'يونيو',
  'يوليو',
  'أغسطس',
  'سبتمبر',
  'أكتوبر',
  'نوفمبر',
  'ديسمبر',
];
const _en = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Its name, 1-12; another number is said as it is.
String monthName(int month, {bool isAr = true}) =>
    month >= 1 && month <= 12 ? (isAr ? _ar : _en)[month - 1] : '$month';
