import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// UI-0 (ADR-049): حجم الخط يأتي من الثيم (`Theme.of(context).textTheme`)،
/// لا من رقم مكتوب في الشاشة.
///
/// الشاشات القديمة فيها أحجام مكتوبة بأرقامها (أكثر من عشرين قيمة)؛ لكل ملف
/// حدّ هو عدده يوم وُضع الحارس (`test/theme_font_size_baseline.json`). العدد
/// ينزل ولا يصعد، والملف الجديد حدّه صفر. لا يُستثنى إلا مصدر الخطوط
/// (`lib/theme/`) وقوالب الطباعة (`lib/pdf/`)، فللورق مقاسه.
///
/// بعد تنظيف شاشة يُخفَّض حدّها:
///   UPDATE_FONT_SIZE_BASELINE=1 flutter test test/theme_font_size_ratchet_test.dart
final ratchet = SourceRatchet(
  pattern: RegExp(r'\bfontSize:\s*[0-9]'),
  baselinePath: 'test/theme_font_size_baseline.json',
  updateEnv: 'UPDATE_FONT_SIZE_BASELINE',
  skipDirs: const ['lib/theme/', 'lib/pdf/'],
);

void main() {
  test('what counts as a written font size', () {
    int n(String s) => ratchet.countIn(s);
    expect(n('TextStyle(fontSize: 12)'), 1);
    expect(n('style.copyWith(fontSize: 11.5, color: c)'), 1);
    expect(n('pw.TextStyle(fontSize: 9)'), 1);
    expect(n('TextStyle(fontSize: size)'), 0);
    expect(n('Theme.of(context).textTheme.bodySmall'), 0);
    expect(n('// fontSize: 12'), 0);
  });

  test('no file gains a written font size', () {
    expect(
      ratchet.grown(),
      isEmpty,
      reason:
          'أحجام خطوط مكتوبة بأرقامها زادت. خذ الحجم من الثيم '
          '(Theme.of(context).textTheme).',
    );
  });
}
