import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// CHART-002 (الإصدار 5ج): الشاشة تأخذ الحساب برابطه أو بدوره من الخادم —
/// روابط الموظف (`payable_accounts`) ومجموعات `/app-config` (`account_groups`)
/// — لا برقمه. كانت شاشة السند تجد ذمم رواتب الموظف بالبادئة «2400» والاسم،
/// ومكافآته بـ«2310»، وحسابه بـ«170/171»، والمصروفات بـ«5»، وتختار 1400
/// «ضريبة المدخلات» لاسترداد السلفة؛ وكانت نصوص تظهر للمستخدم تذكر «(2400)»
/// و«(215)». ترقيم 2027 جديد، فرقم في الشاشة يخطئ بعده.
///
/// لا يُسمح بشيء من ذلك في `lib` (إلا `_archived` المستثنى من البناء).
final patterns = <String, RegExp>{
  'بحث بالبادئة': RegExp(r"startsWith\('\d+'\)"),
  'مقارنة برقم حساب': RegExp(r"account_number'\]\??\.toString\(\)\??\s*==\s*'\d+'"),
  'حساب برقمه': RegExp(r"_findAccountIdByNumber\('\d+'\)"),
  'رقم حساب في نص': RegExp(r"'[^']*\(\d{3,}x*\)[^']*'"),
};

void main() {
  test('no screen names an account by its number', () {
    final found = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => !f.path.replaceAll(r'\', '/').contains('/_archived/'));
    for (final file in files) {
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (line.trimLeft().startsWith('//')) continue;
        patterns.forEach((kind, re) {
          if (re.hasMatch(line)) {
            found.add('${file.path}:${i + 1} ($kind): ${line.trim()}');
          }
        });
      }
    }
    expect(found, isEmpty,
        reason: 'خذ الحساب برابطه أو بدوره من الخادم، لا برقمه:\n${found.join('\n')}');
  });
}
