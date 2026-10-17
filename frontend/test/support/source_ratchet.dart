import 'dart:convert';
import 'dart:io';

/// سقّاطة على الكود: نمط يُعدّ في كل ملف من `lib/`، ولكل ملف حدّ هو عدده
/// يوم وُضع الحارس ([baselinePath]). العدد ينزل ولا يصعد، وأي ملف ليس في
/// الخط القاعدي حدّه صفر.
///
/// بعد تنظيف ملف يُخفَّض حدّه بتشغيل الاختبار و[updateEnv] = 1؛ التحديث
/// يُخفِّض ولا يرفع.
/// The baseline after an update: a file may go down or drop out, never up;
/// and a file not in it stays out -- its limit is zero, and an update does not
/// write its count in as a limit (it let in another session's work in
/// progress, 17 Oct 2026).
Map<String, int> lowerBaseline(
  Map<String, int> now,
  Map<String, int> baseline,
) => {
  for (final e in now.entries)
    if (baseline.containsKey(e.key))
      e.key: e.value <= baseline[e.key]! ? e.value : baseline[e.key]!,
};

class SourceRatchet {
  const SourceRatchet({
    required this.pattern,
    required this.baselinePath,
    required this.updateEnv,
    this.skipDirs = const [],
    this.ignoreLine,
  });

  final RegExp pattern;
  final String baselinePath;
  final String updateEnv;

  /// مجلدات أو ملفات تحت `lib/` لا تُعدّ (مصدر القيم نفسه).
  final List<String> skipDirs;

  /// أسطر لا تُعدّ وإن طابقت (سطر سجلّ مثلًا).
  final RegExp? ignoreLine;

  /// عدد مرات النمط في نص، والأسطر التي تبدأ بـ `//` لا تُعدّ.
  int countIn(String text) => text
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('//'))
      .where((line) => ignoreLine == null || !ignoreLine!.hasMatch(line))
      .map((line) => pattern.allMatches(line).length)
      .fold<int>(0, (a, b) => a + b);

  Map<String, int> count() {
    final counts = <String, int>{};
    final files =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      if (skipDirs.any(path.startsWith)) continue;
      final n = countIn(file.readAsStringSync());
      if (n > 0) counts[path] = n;
    }
    return counts;
  }

  /// الملفات التي زاد عددها على حدّها، بصيغة `ملف: العدد (الحدّ ن)`.
  ///
  /// مع [updateEnv] = 1 يُكتب الخط القاعدي مُخفَّضًا ويُرجع فارغًا.
  List<String> grown() {
    final now = count();
    final file = File(baselinePath);
    final baseline = file.existsSync()
        ? Map<String, int>.from(jsonDecode(file.readAsStringSync()) as Map)
        : <String, int>{};

    if (Platform.environment[updateEnv] == '1') {
      final lowered = lowerBaseline(now, baseline);
      file.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(lowered)}\n',
      );
      return const [];
    }

    return [
      for (final e in now.entries)
        if (e.value > (baseline[e.key] ?? 0))
          '${e.key}: ${e.value} (الحدّ ${baseline[e.key] ?? 0})',
    ];
  }
}
