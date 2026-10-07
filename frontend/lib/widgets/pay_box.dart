import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_semantic_colors.dart';
import '../utils.dart';

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
              _button(methods[i], prominent: i < 2, shortcut: i + 1),
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
    Map<String, dynamic> method, {
    required bool prominent,
    required int shortcut,
  }) {
    final rate = method['commission_rate'] ?? 0;
    // The rate isolated left-to-right: «(0.8%)», not «(%0.8)».
    final ltr = String.fromCharCode(0x2066);
    final pop = String.fromCharCode(0x2069);
    final label = Text(
      '${method['name'] ?? ''}${rate > 0 ? ' ($ltr$rate%$pop)' : ''}',
    );
    final icon = Icon(
      paymentMethodIcon('${method['payment_type'] ?? ''}'),
      size: 18,
    );
    final key = Key('quick-pay-${method['id']}');
    void press() => onPay(method['id'] as int);
    final button = prominent
        ? FilledButton.icon(
            key: key,
            onPressed: press,
            icon: icon,
            label: label,
          )
        : OutlinedButton.icon(
            key: key,
            onPressed: press,
            icon: icon,
            label: label,
          );
    return shortcut <= 9
        ? Tooltip(message: 'Alt+$shortcut', child: button)
        : button;
  }
}
