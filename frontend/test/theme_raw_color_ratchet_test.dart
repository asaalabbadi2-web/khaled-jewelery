import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ثيم-٠: الألوان تأتي من الثيم (`Theme.of(context).colorScheme` و
/// `AppSemanticColors.of(context)`)، لا من قيمة مكتوبة في الشاشة.
///
/// الشاشات القديمة فيها ألوان مكتوبة بقيمتها؛ لكل ملف حدّ هو عدده يوم
/// الإصلاح ([baselinePath]). العدد يمكن أن ينزل ولا يصعد، وأي ملف ليس في
/// الخط القاعدي حدّه صفر. لا يُستثنى إلا مصدر الألوان نفسه ([themeDir]).
///
/// بعد تنظيف شاشة يُخفَّض حدّها:
///   UPDATE_COLOR_BASELINE=1 flutter test test/theme_raw_color_ratchet_test.dart
const baselinePath = 'test/theme_raw_color_baseline.json';
const themeDir = 'lib/theme/';

final rawColor = RegExp(
  r'Color\(0x|Color\.fromARGB\(|Color\.fromRGBO\(|'
  r'Colors\.(?!transparent\b)[a-zA-Z]+',
);

Map<String, int> countRawColors() {
  final counts = <String, int>{};
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final path = file.path.replaceAll(r'\', '/');
    if (path.startsWith(themeDir)) continue;
    final n = file
        .readAsLinesSync()
        .where((line) => !line.trimLeft().startsWith('//'))
        .map((line) => rawColor.allMatches(line).length)
        .fold<int>(0, (a, b) => a + b);
    if (n > 0) counts[path] = n;
  }
  return counts;
}

void main() {
  test('no file gains a raw color', () {
    final now = countRawColors();

    if (Platform.environment['UPDATE_COLOR_BASELINE'] == '1') {
      final baseline = File(baselinePath).existsSync()
          ? Map<String, int>.from(
              jsonDecode(File(baselinePath).readAsStringSync()) as Map,
            )
          : <String, int>{};
      // Lowering only: a file may go down or drop out, never up.
      final lowered = <String, int>{
        for (final e in now.entries)
          if (!baseline.containsKey(e.key) || e.value <= baseline[e.key]!)
            e.key: e.value
          else
            e.key: baseline[e.key]!,
      };
      File(baselinePath).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(lowered)}\n',
      );
      return;
    }

    final baseline = Map<String, int>.from(
      jsonDecode(File(baselinePath).readAsStringSync()) as Map,
    );
    final grew = <String>[
      for (final e in now.entries)
        if (e.value > (baseline[e.key] ?? 0))
          '${e.key}: ${e.value} (الحدّ ${baseline[e.key] ?? 0})',
    ];
    expect(
      grew,
      isEmpty,
      reason:
          'ألوان مكتوبة بقيمتها زادت. خذ اللون من الثيم '
          '(colorScheme أو AppSemanticColors.of(context)).',
    );
  });
}
