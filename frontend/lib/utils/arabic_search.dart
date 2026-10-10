import '../utils.dart' show normalizeNumber;

final _diacritics = RegExp('[ً-ٰٟـ]'); // tashkeel, superscript alef, tatweel

/// A string as a search compares it: Arabic letter forms unified (أ إ آ ٱ →
/// ا, ة → ه, ى → ي, ؤ → و, ئ → ي), diacritics and tatweel dropped, Arabic-Indic
/// digits made Latin, lower-cased. So «الأصول» finds «الاصول», «مؤسسة» finds
/// «موسسه», and «١١٠» finds account 110 (the owner, 10 Oct 2026).
String normalizeForSearch(String? input) {
  var s = normalizeNumber(input ?? '').toLowerCase().replaceAll(_diacritics, '');
  s = s
      .replaceAll(RegExp('[أإآٱ]'), 'ا')
      .replaceAll('ة', 'ه')
      .replaceAll('ى', 'ي')
      .replaceAll('ؤ', 'و')
      .replaceAll('ئ', 'ي');
  return s.trim();
}
