import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../theme/app_semantic_colors.dart';

/// Each employee's owed amount from the books, and where it differs from
/// their approved unpaid bonuses, the difference said plainly -- it was paid,
/// reversed or entered in the books outside the bonus screen (BONUS-BOOKS-1,
/// the owner 14 Oct 2026: the books are right). No voucher is matched to a
/// bonus by guess. Rows are GET /bonuses/owed's `employees`.
class BonusOwedFromBooksCard extends StatelessWidget {
  const BonusOwedFromBooksCard({super.key, required this.rows, this.isArabic = true});

  final List<Map<String, dynamic>> rows;
  final bool isArabic;

  /// The direction said, not a signed number: the books lower (paid or entered
  /// outside the screen) or higher (a payment reversed, or entered outside).
  static String _differenceText(bool isAr, String approved, String gap, bool booksLower) {
    if (isAr) {
      return booksLower
          ? 'المعتمد غير المصروف $approved — الدفاتر أقل بـ $gap: صُرف أو قُيّد خارج شاشة المكافآت'
          : 'المعتمد غير المصروف $approved — الدفاتر أكثر بـ $gap: عُكس صرفٌ أو قُيّد خارج شاشة المكافآت';
    }
    return booksLower
        ? 'Approved unpaid $approved -- the books $gap lower: paid or entered outside the bonus screen'
        : 'Approved unpaid $approved -- the books $gap higher: a payment reversed or entered outside';
  }

  @override
  Widget build(BuildContext context) {
    final isAr = isArabic;
    final scheme = Theme.of(context).colorScheme;
    final tones = AppSemanticColors.of(context);
    final currency = context.read<SettingsProvider>().currencySymbolText;
    final digits = NumberFormat('#,##0.00', 'en');
    String money(num v) => '${digits.format(v)} $currency';
    num value(Map<String, dynamic> row, String key) => (row[key] as num?) ?? 0;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              isAr ? 'المستحق للموظفين في الدفاتر' : 'Owed to employees in the books',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              isAr
                  ? 'الدفاتر هي المرجع: سند صرف أو عكسه أو قيد يدوي على حساب الموظف يغيّرها ولا يغيّر حالة المكافأة.'
                  : 'The books are the reference: a voucher, its reversal or a manual entry moves them, not a bonus status.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            for (final row in rows) ...[
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${row['employee_name'] ?? ''}',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  Text(
                    money(value(row, 'owed_in_books')),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (value(row, 'difference').abs() >= 0.005)
                Padding(
                  padding: const EdgeInsets.only(top: 2, bottom: 6),
                  child: Text(
                    _differenceText(isAr, money(value(row, 'approved_unpaid')),
                        money(value(row, 'difference').abs()), value(row, 'difference') > 0),
                    style: TextStyle(fontSize: 12, color: tones.warning.fg),
                  ),
                )
              else
                const SizedBox(height: 6),
            ],
          ],
        ),
      ),
    );
  }
}
