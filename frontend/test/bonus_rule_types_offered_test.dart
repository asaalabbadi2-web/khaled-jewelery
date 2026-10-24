import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/bonus_rule_model.dart';

/// A rule type is offered only where the server computes it (bonus study م0,
/// ث10): «مخصصة» had no branch in the calculator -- a rule of it paid nothing,
/// unsaid -- and «الحضور» / «الأداء» are refused by their flag, off, with
/// figures fixed in the code. A rule already of one keeps it in its form.
void main() {
  test('a new rule is offered the types the server computes', () {
    // The tiered rule says what «على أساس النقاط» said and more (bonus study
    // م2): the points rule is no longer offered for a new one.
    expect(BonusRuleModel.ruleTypesFor(null),
        ['tiered', 'sales_target', 'fixed', 'profit_based']);
  });

  test('a rule already of another type keeps it, to be seen and changed', () {
    expect(BonusRuleModel.ruleTypesFor('points_based'),
        ['tiered', 'sales_target', 'fixed', 'profit_based', 'points_based']);
  });
}
