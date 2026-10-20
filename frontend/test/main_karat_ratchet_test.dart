import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// The main karat is the settings' -- never a fixed one (the owner, 20 Oct
/// 2026: «يمنع استخدام عيار ثابت كعيار رئيسي، فقط ديناميكي من الإعدادات»).
/// One source: SettingsProvider.mainKarat, read from the settings
/// (lib/providers is not counted: its default is that source's).
///
/// Counted: a main karat set to 21 (`mainKarat = 21`, `?? 21`, `: 21` as a
/// default, `? 21 :`; the server's `main_karat` falling back to 21 or '21'
/// -- missed until 20 Oct 2026), and a division by 21 -- a weight brought to 21. Not
/// counted: 21 as a karat's own fineness (`w * 21 / main`, `21.0 / main`).
/// Each file may go down and never up; a new file's count is zero
/// (`test/main_karat_baseline.json`). After a screen reads the settings':
///   UPDATE_MAIN_KARAT_BASELINE=1 flutter test test/main_karat_ratchet_test.dart
final ratchet = SourceRatchet(
  pattern: RegExp(
    r"[mM]ain_?[kK]arat\w*\s*(=|\?\?|:)\s*'?21\b"
    r"|main_karat'\][^;\n]{0,40}\?\?\s*'?21\b"
    r'|\?\s*21(\.0)?\s*:'
    r'|/\s*21(\.0)?\b',
  ),
  baselinePath: 'test/main_karat_baseline.json',
  updateEnv: 'UPDATE_MAIN_KARAT_BASELINE',
  skipDirs: const ['lib/providers'],
);

void main() {
  test('what counts', () {
    int n(String s) => ratchet.countIn(s);
    expect(n('int _mainKarat = 21;'), 1);
    expect(n('final mainKarat = 21.0;'), 1);
    expect(n('(_overview?.mainKarat ?? 21)'), 1);
    expect(n("json['main_karat'] ?? 21"), 1);
    expect(n("(_toDouble(voucher['main_karat']) ?? 21).round()"), 1);
    expect(n("(json['main_karat'] as num?)?.toDouble() ?? 21,"), 1);
    expect(n("g['main_karat']?.toString() ?? '21';"), 1);
    expect(n('this.mainKarat = 21,'), 1);
    expect(n('final main = k <= 0 ? 21.0 : k;'), 1);
    expect(n('w18 * (18.0 / 21.0)'), 1);
    expect(n('w21 * (21.0 / main)'), 0);
    expect(n('weight * 21 / mainKarat'), 0);
    expect(n('context.read<SettingsProvider>().mainKarat'), 0);
  });

  test('no file gains a fixed main karat', () {
    expect(
      ratchet.grown(),
      isEmpty,
      reason:
          'عيار رئيسي ثابت زاد. اقرأه من الإعدادات: '
          'context.read<SettingsProvider>().mainKarat.',
    );
  });
}
