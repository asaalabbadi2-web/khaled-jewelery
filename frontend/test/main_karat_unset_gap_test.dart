import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';

/// MAIN-KARAT-UI-1 (Known Gaps, docs/architecture/architecture-v1.md §4.6): the
/// owner, 20 Oct 2026, «يمنع استخدام عيار ثابت كعيار رئيسي، فقط ديناميكي من
/// الإعدادات». The server refuses an unset main karat (`main_karat_not_set`);
/// SettingsProvider.mainKarat -- the screens' one source -- reads 21 while the
/// settings are not loaded or hold none.
///
/// This test pins the gap as it is. The fix (the karat unset is said, not
/// guessed) turns it red: close the gap with it, and turn this into the fix's test.
void main() {
  test('MAIN-KARAT-UI-1: unset or not yet loaded, the main karat reads 21 -- the gap', () {
    expect(SettingsProvider().mainKarat, 21,
        reason: 'fixed? close MAIN-KARAT-UI-1 in §4.6 and make this the test of the fix');
  });
}
