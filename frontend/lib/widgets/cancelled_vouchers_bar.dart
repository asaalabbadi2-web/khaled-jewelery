import 'package:flutter/material.dart';

import '../utils/bidi.dart';

/// Says how many cancelled vouchers a statement or a list leaves out, and
/// shows or hides them (the owner, 9 Oct 2026: hidden by default, a button
/// shows them). The server decides which, and that a hidden pair never moves
/// a balance (services/cancelled_vouchers.py); this only says it.
///
/// One quiet line, no box (the owner: the first bar took too much room).
class CancelledVouchersBar extends StatelessWidget {
  final int count;

  /// Payment-method corrections hidden with their payment (statements only).
  final int corrections;
  final bool hidden;
  final bool busy;
  final VoidCallback onToggle;

  /// «مع قيودها العكسية» where the entries are shown (statements, the journal);
  /// the voucher list shows vouchers alone.
  final bool withReversals;

  const CancelledVouchersBar({
    super.key,
    required this.count,
    this.corrections = 0,
    required this.hidden,
    required this.onToggle,
    this.busy = false,
    this.withReversals = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final parts = [
      if (count > 0) '${ltrIsolate('$count')} ملغى',
      if (corrections > 0) '${ltrIsolate('$corrections')} تصحيح وسيلة دفع',
    ].join(' · ');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
          size: 14,
          color: theme.hintColor,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            hidden ? 'مخفي $parts' : 'ظاهر $parts',
            style: muted,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Tooltip(
          message: [
            withReversals ? 'السندات الملغاة مع قيودها العكسية' : 'السندات الملغاة',
            if (corrections > 0) 'وتصحيحات وسيلة الدفع في كشف الوسيلة الخاطئة',
            if (withReversals) '— لا يتغيّر بها الرصيد',
          ].join(' '),
          child: TextButton(
            onPressed: busy ? null : onToggle,
            style: TextButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              minimumSize: const Size(0, 28),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(hidden ? 'إظهار' : 'إخفاء'),
          ),
        ),
      ],
    );
  }
}
