import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// ثيم-٠: الألوان تأتي من الثيم (`Theme.of(context).colorScheme` و
/// `AppSemanticColors.of(context)`)، لا من قيمة مكتوبة في الشاشة.
///
/// الشاشات القديمة فيها ألوان مكتوبة بقيمتها؛ لكل ملف حدّ هو عدده يوم
/// الإصلاح (`test/theme_raw_color_baseline.json`). العدد يمكن أن ينزل ولا يصعد، وأي ملف ليس في
/// الخط القاعدي حدّه صفر. لا يُستثنى إلا مصدر الألوان نفسه (`lib/theme/`).
///
/// بعد تنظيف شاشة يُخفَّض حدّها:
///   UPDATE_COLOR_BASELINE=1 flutter test test/theme_raw_color_ratchet_test.dart
final ratchet = SourceRatchet(
  // `Colors.` also matches `AppColors.` -- on purpose: AppColors are fixed
  // values that do not follow the dark theme either. `AppSemanticColors.` is
  // the theme itself and is not counted.
  pattern: RegExp(
    r'Color\(0x|Color\.fromARGB\(|Color\.fromRGBO\(|'
    r'(?<!Semantic)Colors\.(?!transparent\b)[a-zA-Z]+',
  ),
  baselinePath: 'test/theme_raw_color_baseline.json',
  updateEnv: 'UPDATE_COLOR_BASELINE',
  skipDirs: const ['lib/theme/'],
);

void main() {
  test('what counts as a raw color', () {
    int n(String s) => ratchet.countIn(s);
    expect(n('color: Colors.black54'), 1);
    expect(n('Color(0xFFFAF5E4)'), 1);
    expect(n('AppColors.info'), 1);
    expect(n('AppSemanticColors.of(context).info.fg'), 0);
    expect(n('Colors.transparent'), 0);
    expect(n('// Colors.red'), 0);
  });

  test('no file gains a raw color', () {
    expect(
      ratchet.grown(),
      isEmpty,
      reason:
          'ألوان مكتوبة بقيمتها زادت. خذ اللون من الثيم '
          '(colorScheme أو AppSemanticColors.of(context)).',
    );
  });
}
