import 'journal_balance.dart';

/// Whether a manual journal entry can be saved, and if not, the first reason.
///
/// «Ready» means what the server will accept (backend/routes/journals.py):
/// at least two valued lines, every one on an existing leaf account, cash
/// balanced, gold balanced to the server's settlement limit, and a
/// description. A balanced entry with a line missing its account is NOT
/// ready -- the screen must never show success for an entry it cannot save.
enum JournalReadinessKind { empty, notReady, ready }

class JournalLineFacts {
  final bool hasValues;
  final bool hasAccount;
  final bool accountIsParent;
  final bool accountMissing;

  const JournalLineFacts({
    required this.hasValues,
    required this.hasAccount,
    this.accountIsParent = false,
    this.accountMissing = false,
  });
}

class JournalReadiness {
  final JournalReadinessKind kind;

  /// Arabic, for the accountant; empty when ready.
  final String message;

  /// The first line to look at (0-based), when the reason is a line.
  final int? lineIndex;

  /// Ready, with a gold gap under the limit the server closes by itself.
  final bool goldWillBeSettled;

  const JournalReadiness._(
    this.kind, {
    this.message = '',
    this.lineIndex,
    this.goldWillBeSettled = false,
  });

  bool get isReady => kind == JournalReadinessKind.ready;
}

JournalReadiness journalReadiness({
  required String description,
  required List<JournalLineFacts> lines,
  required double cashDebit,
  required double cashCredit,
  required double goldDebit,
  required double goldCredit,
  required String Function(double) formatCash,
}) {
  JournalReadiness notReady(String message, [int? lineIndex]) =>
      JournalReadiness._(
        JournalReadinessKind.notReady,
        message: message,
        lineIndex: lineIndex,
      );

  final valued = <int>[
    for (var i = 0; i < lines.length; i++)
      if (lines[i].hasValues) i,
  ];
  if (valued.isEmpty) {
    return const JournalReadiness._(
      JournalReadinessKind.empty,
      message: 'أدخل مبالغ القيد',
    );
  }

  for (final i in valued) {
    final line = lines[i];
    if (!line.hasAccount) return notReady('اختر حساباً للسطر ${i + 1}', i);
    if (line.accountMissing) {
      return notReady('حساب السطر ${i + 1} غير موجود؛ اختر حساباً آخر', i);
    }
    if (line.accountIsParent) {
      return notReady('السطر ${i + 1} على حساب رئيسي؛ اختر حساباً فرعياً', i);
    }
  }

  if (valued.length < 2) return notReady('أضف سطراً ثانياً على الأقل');

  final cashGap = (cashDebit - cashCredit).abs();
  if (cashGap > kBalanceTolerance) {
    return notReady('النقد غير متوازن: الفرق ${formatCash(cashGap)}');
  }

  final gold = goldBalanceVerdict(goldDebit, goldCredit);
  if (gold == GoldBalanceVerdict.mustFix) {
    final gap = (goldDebit - goldCredit).abs().toStringAsFixed(4);
    return notReady('الذهب غير متوازن: الفرق $gap غ');
  }

  if (description.trim().isEmpty) return notReady('اكتب بيان القيد');

  return JournalReadiness._(
    JournalReadinessKind.ready,
    goldWillBeSettled: gold == GoldBalanceVerdict.serverWillSettle,
  );
}
