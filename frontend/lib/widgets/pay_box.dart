import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_button_styles.dart';
import '../theme/app_semantic_colors.dart';
import '../utils.dart';
import '../utils/payment_fee.dart';

/// The icon of a payment method by its type.
IconData paymentMethodIcon(String paymentType) => switch (paymentType) {
  'cash' => Icons.money,
  'bank_transfer' => Icons.account_balance,
  'credit_card' || 'mada' => Icons.credit_card,
  'check' => Icons.receipt_long,
  'other' => Icons.more_horiz,
  _ => Icons.payment,
};

/// One way to pay (SALES-UX-4), for a sale and for a purchase alike: an
/// amount (empty pays what remains, shown as its hint) and the methods'
/// buttons -- type, press, and the last press takes the rest, for any number
/// of methods or the same one twice. The first two in the settings' order
/// stand out; Alt+1 … Alt+9 press them (the screen binds the keys).
class PayBox extends StatelessWidget {
  final TextEditingController amount;
  final double remaining;
  final String currency;
  final List<Map<String, dynamic>> methods;
  final ValueChanged<int> onPay;

  /// The remaining, as the screen writes money (currency-aware).
  final Widget remainingText;

  const PayBox({
    super.key,
    required this.amount,
    required this.remaining,
    required this.currency,
    required this.methods,
    required this.onPay,
    required this.remainingText,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: amount,
          inputFormatters: [
            NormalizeNumberFormatter(),
            FilteringTextInputFormatter.deny(RegExp('[,،]')),
            FilteringTextInputFormatter.allow(RegExp(r'^[0-9]*\.?[0-9]*$')),
          ],
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(
            labelText: 'المبلغ',
            hintText: remaining.toStringAsFixed(2),
            helperText: 'فارغًا يُدفع المتبقي كله',
            suffixText: currency,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < methods.length; i++)
              _button(context, methods[i], prominent: i < 2, shortcut: i + 1),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: tones.warning.container,
            borderRadius: BorderRadius.circular(6),
          ),
          child: DefaultTextStyle.merge(
            style: theme.textTheme.bodyMedium?.copyWith(
              color: tones.warning.onContainer,
              fontWeight: FontWeight.bold,
            ),
            child: remainingText,
          ),
        ),
      ],
    );
  }

  Widget _button(
    BuildContext context,
    Map<String, dynamic> method, {
    required bool prominent,
    required int shortcut,
  }) {
    // What it deducts, its rate and its fixed amount (COMMISSION-3), isolated
    // left-to-right: «(0.8%)», «(6.99% + 1.5)», not «(%0.8)».
    final fee = PaymentFee.of(method, 0, vatRate: 0);
    final deducts = PaymentFee.label(fee.rate, fee.fixed);
    final ltr = String.fromCharCode(0x2066);
    final pop = String.fromCharCode(0x2069);
    final label = Text(
      '${method['name'] ?? ''}${deducts.isNotEmpty ? ' ($ltr$deducts$pop)' : ''}',
    );
    final icon = Icon(
      paymentMethodIcon('${method['payment_type'] ?? ''}'),
      size: 18,
    );
    final key = Key('quick-pay-${method['id']}');
    void press() => onPay(method['id'] as int);
    // The ways to pay wear the cash tone, set apart from the screen's other
    // soft buttons (the owner, 17 Oct 2026: they looked like the rest): the
    // methods used most filled with its light color and framed in its strong
    // one, the others framed only. Each pair is tested 4.5:1 (ADR-049).
    final cash = AppSemanticColors.of(context).cash;
    final button = prominent
        ? FilledButton.tonalIcon(
            key: key,
            onPressed: press,
            icon: icon,
            label: label,
            style: AppButtonStyles.kind(cash),
          )
        : OutlinedButton.icon(
            key: key,
            onPressed: press,
            icon: icon,
            label: label,
            style: OutlinedButton.styleFrom(
              foregroundColor: cash.fg,
              side: BorderSide(color: cash.fg.withValues(alpha: 0.6)),
            ),
          );
    return shortcut <= 9
        ? Tooltip(message: 'Alt+$shortcut', child: button)
        : button;
  }
}
