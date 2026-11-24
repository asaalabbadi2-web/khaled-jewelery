// ADR-100: a sale by a method with plans names the customer's plan, and the
// owner sets the plans, the fee a deposit and order-by-order on the method.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/payment_plans_editor.dart';
import 'package:frontend/widgets/plan_picker.dart';

void main() {
  final tamara = {
    'name': 'تمارا',
    'plans': [
      {'installments': 2, 'commission_rate': 6.99},
      {'installments': 4, 'commission_rate': 6.99},
      {'installments': 6, 'commission_rate': 5.99},
    ],
  };

  Future<int?> pick(WidgetTester tester, Map<String, dynamic> method, {String? tap}) async {
    int? chosen = -1;
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await choosePaymentPlan(context, method),
            child: const Text('ادفع'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('ادفع'));
    await tester.pumpAndSettle();
    if (tap != null) {
      await tester.tap(find.byKey(Key(tap)));
    } else {
      await tester.tap(find.text('إلغاء'));
    }
    await tester.pumpAndSettle();
    return chosen;
  }

  testWidgets('the cashier chooses the customer\'s plan', (tester) async {
    expect(await pick(tester, tamara, tap: 'payment-plan-6'), 6);
  });

  testWidgets('closed without a plan, nothing is chosen', (tester) async {
    expect(await pick(tester, tamara), isNull);
  });

  testWidgets('a method without plans asks nothing', (tester) async {
    int? chosen = -1;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => chosen = await choosePaymentPlan(context, {'name': 'مدى'}),
          child: const Text('ادفع'),
        ),
      ),
    ));
    await tester.tap(find.text('ادفع'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(chosen, isNull);
  });

  test('the method\'s terms are read from it, and a repeated plan is refused', () {
    final terms = PaymentFeeTerms.fromMethod({
      ...tamara,
      'deposit_fixed_fee': 6.0,
      'commission_per_order': true,
    });
    expect(terms.plans, [(2, 6.99), (4, 6.99), (6, 5.99)]);
    expect((terms.depositFixedFee, terms.perOrder), (6.0, true));
    expect(terms.error, isNull);
    expect(PaymentFeeTerms(plans: [(4, 6.99), (4, 5.99)], depositFixedFee: 0, perOrder: true).error,
        'الخطة 4 دفعات مكرّرة');
  });

  testWidgets('the editor adds a plan and says the fee a deposit', (tester) async {
    PaymentFeeTerms? last;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: PaymentPlansEditor(
            initial: PaymentFeeTerms.fromMethod(null),
            onChanged: (t) => last = t,
          ),
        ),
      ),
    ));
    await tester.enterText(find.byKey(const Key('payment-method-deposit-fee')), '6');
    await tester.tap(find.byKey(const Key('payment-plan-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('payment-plan-installments-0')), '4');
    await tester.enterText(find.byKey(const Key('payment-plan-rate-0')), '6.99');
    await tester.tap(find.byKey(const Key('payment-method-per-order')));
    await tester.pumpAndSettle();
    expect(last!.depositFixedFee, 6.0);
    expect(last!.plans, [(4, 6.99)]);
    expect(last!.perOrder, isTrue);
    await tester.tap(find.byKey(const Key('payment-method-confirm-deposits')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('payment-method-difference-allowed')), '25');
    expect(last!.confirmDeposits, isTrue);
    expect(last!.differenceAllowed, 25.0);
    await tester.tap(find.byKey(const Key('payment-method-half-even')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('payment-method-refundable-rate')), '4.99');
    expect(last!.rounding, 'half_even');
    expect(last!.refundableRate, 4.99);
  });
}
