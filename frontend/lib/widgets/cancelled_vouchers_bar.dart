import 'package:flutter/material.dart';

import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';

/// Says how many cancelled vouchers a statement or a list leaves out, and
/// shows or hides them (the owner, 9 Oct 2026: hidden by default, a button
/// shows them). The server decides which, and that a hidden pair never moves
/// a balance (services/cancelled_vouchers.py); this only says it.
class CancelledVouchersBar extends StatelessWidget {
  final int count;
  final bool hidden;
  final bool busy;
  final VoidCallback onToggle;

  /// «مع قيودها العكسية» where the entries are shown (statements, the journal);
  /// the voucher list shows vouchers alone.
  final bool withReversals;

  const CancelledVouchersBar({
    super.key,
    required this.count,
    required this.hidden,
    required this.onToggle,
    this.busy = false,
    this.withReversals = true,
  });

  @override
  Widget build(BuildContext context) {
    final tone = AppSemanticColors.of(context).info;
    final what = withReversals
        ? 'من السندات الملغاة مع قيودها العكسية'
        : 'من السندات الملغاة';
    final n = ltrIsolate('$count');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(
            hidden ? Icons.visibility_off_outlined : Icons.visibility_outlined,
            size: 18,
            color: tone.onContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hidden
                  ? 'أُخفيت $n $what${withReversals ? ' — لا يتغيّر بها الرصيد' : ''}'
                  : 'تُعرض $n $what',
              style: TextStyle(color: tone.onContainer, fontSize: 13),
            ),
          ),
          TextButton(
            onPressed: busy ? null : onToggle,
            child: Text(hidden ? 'إظهار' : 'إخفاء'),
          ),
        ],
      ),
    );
  }
}
