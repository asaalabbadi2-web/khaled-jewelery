import 'package:flutter/material.dart';

import '../utils/bidi.dart';
import '../utils/payment_fee.dart';

/// The plan a payment by a method with plans names (ADR-100) -- the plans
/// and their rates the method's settings. The cashier asks the customer -- it
/// shows in the company's app once bought. Null when the method has
/// no plans, or the cashier closed it without choosing.
Future<int?> choosePaymentPlan(
  BuildContext context,
  Map<String, dynamic> method, {
  int? current,
}) async {
  final plans = PaymentFee.plansOf(method);
  if (plans.isEmpty) return null;
  return showDialog<int>(
    context: context,
    builder: (ctx) => PaymentPlanDialog(
      methodName: '${method['name'] ?? ''}',
      plans: plans,
      current: current,
    ),
  );
}

class PaymentPlanDialog extends StatelessWidget {
  const PaymentPlanDialog({
    super.key,
    required this.methodName,
    required this.plans,
    this.current,
  });

  final String methodName;
  final Map<int, double> plans;
  final int? current;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String rate(double v) => v == v.roundToDouble() ? '${v.toInt()}%' : '$v%';
    return AlertDialog(
      title: Text('خطة $methodName'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'عدد الدفعات كما اختاره العميل في تطبيق $methodName',
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entry in plans.entries)
                ChoiceChip(
                  key: Key('payment-plan-${entry.key}'),
                  selected: entry.key == current,
                  label: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('${entry.key} دفعات', style: const TextStyle(fontWeight: FontWeight.w700)),
                      Text(ltrIsolate(rate(entry.value)), style: theme.textTheme.labelSmall),
                    ],
                  ),
                  onSelected: (_) => Navigator.of(context).pop(entry.key),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('إلغاء')),
      ],
    );
  }
}
