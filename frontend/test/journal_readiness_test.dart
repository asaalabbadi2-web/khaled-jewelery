import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/journal_readiness.dart';

/// JE-UX-2: the entry screen says «ready» only when the server would accept
/// the entry -- balanced AND every valued line on a usable account. A balanced
/// entry with a line missing its account is not ready, and names the line.
void main() {
  const valued = JournalLineFacts(hasValues: true, hasAccount: true);
  String cash(double v) => v.toStringAsFixed(2);

  JournalReadiness judge(
    List<JournalLineFacts> lines, {
    String description = 'بيان',
    double cashDebit = 100,
    double cashCredit = 100,
    double goldDebit = 0,
    double goldCredit = 0,
  }) => journalReadiness(
    description: description,
    lines: lines,
    cashDebit: cashDebit,
    cashCredit: cashCredit,
    goldDebit: goldDebit,
    goldCredit: goldCredit,
    formatCash: cash,
  );

  test('nothing entered is empty, not an error', () {
    final r = judge(
      const [JournalLineFacts(hasValues: false, hasAccount: false)],
      cashDebit: 0,
      cashCredit: 0,
    );
    expect(r.kind, JournalReadinessKind.empty);
  });

  test('balanced, but a valued line without an account, is not ready', () {
    final r = judge(const [
      valued,
      valued,
      valued,
      JournalLineFacts(hasValues: true, hasAccount: false),
    ]);
    expect(r.kind, JournalReadinessKind.notReady);
    expect(r.message, 'اختر حساباً للسطر 4');
    expect(r.lineIndex, 3);
  });

  test('an empty line without an account is ignored', () {
    final r = judge(const [
      valued,
      JournalLineFacts(hasValues: false, hasAccount: false),
      valued,
    ]);
    expect(r.kind, JournalReadinessKind.ready);
  });

  test('a parent account is named with its line', () {
    final r = judge(const [
      valued,
      JournalLineFacts(
        hasValues: true,
        hasAccount: true,
        accountIsParent: true,
      ),
    ]);
    expect(r.message, 'السطر 2 على حساب رئيسي؛ اختر حساباً فرعياً');
    expect(r.lineIndex, 1);
  });

  test('one valued line is not an entry', () {
    final r = judge(const [valued]);
    expect(r.message, 'أضف سطراً ثانياً على الأقل');
  });

  test('unbalanced cash names the difference', () {
    final r = judge(const [valued, valued], cashDebit: 2500, cashCredit: 1000);
    expect(r.kind, JournalReadinessKind.notReady);
    expect(r.message, 'النقد غير متوازن: الفرق 1500.00');
    expect(r.lineIndex, isNull);
  });

  test('gold the server refuses is not ready; gold it settles is', () {
    expect(
      judge(const [valued, valued], goldDebit: 10.5, goldCredit: 10).message,
      'الذهب غير متوازن: الفرق 0.5000 غ',
    );
    final settled = judge(
      const [valued, valued],
      goldDebit: 10.0075,
      goldCredit: 10,
    );
    expect(settled.kind, JournalReadinessKind.ready);
    expect(settled.goldWillBeSettled, isTrue);
  });

  test('a missing description comes after the figures', () {
    final r = judge(const [valued, valued], description: '  ');
    expect(r.message, 'اكتب بيان القيد');
  });

  test('balanced and complete is ready', () {
    final r = judge(const [valued, valued]);
    expect(r.kind, JournalReadinessKind.ready);
    expect(r.goldWillBeSettled, isFalse);
  });
}
