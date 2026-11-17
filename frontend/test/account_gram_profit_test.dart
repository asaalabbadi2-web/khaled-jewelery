// Gram profit in the account form (the owner, 17 Nov 2026; ADR-092): the
// switch showed an account's own mark, not whether it counted -- salaries
// counted through «52» with their switch off, and turning it on changed
// nothing. Now every revenue and expense counts but trading and what the
// owner excludes; the form says where the account stands and what decided
// it, and its one switch is the exclusion.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/widgets/account_management.dart';

class _FakeApi extends ApiService {
  final saved = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> validateAccountNumber({
    required String accountNumber,
    required String parentAccountNumber,
    int? excludeAccountId,
  }) async =>
      {'is_valid': true};

  @override
  Future<void> updateAccount(int id, Map<String, dynamic> accountData) async {
    saved.add(accountData);
  }
}

const _zakatGroup = {'id': 59, 'account_number': '59', 'name': 'الزكاة'};

Map<String, dynamic> _account(int id, String number, String name,
        {required Map<String, dynamic> standing, bool excluded = false, int? parentId = 540}) =>
    {
      'id': id,
      'account_number': number,
      'name': name,
      'type': 'Expense',
      'parent_id': parentId,
      'tracks_weight': false,
      'exclude_from_gram_profit': excluded,
      'gram_profit': standing,
    };

final _parent = {'id': 540, 'account_number': '540', 'name': 'المصاريف الإدارية', 'type': 'Expense',
  'parent_id': null, 'tracks_weight': false};

Future<_FakeApi> _open(WidgetTester tester, Map<String, dynamic> editing) async {
  final api = _FakeApi();
  await tester.pumpWidget(MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showAccountForm(context, api: api, accounts: [_parent, editing], editing: editing),
            child: const Text('افتح'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('افتح'));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  test('each standing says itself and what decided it', () {
    final counted = gramProfitSaying({'state': 'counted', 'side': 'expense', 'via': null}, excludedHere: false);
    expect((counted.line, counted.canSwitch, counted.decidedElsewhere),
        ('يدخل في ربح الجرام مصروفًا', true, false));
    final byParent =
        gramProfitSaying({'state': 'excluded', 'side': 'expense', 'via': _zakatGroup}, excludedHere: false);
    expect((byParent.line, byParent.decidedElsewhere, byParent.switchNote),
        ('مستثنى، لأن «59 الزكاة» مستثنى', true, 'يُعاد من «59 الزكاة»'));
    final trading = gramProfitSaying({
      'state': 'trading',
      'side': 'revenue',
      'via': {'id': 1, 'account_number': '400', 'name': 'مبيعات ذهب جديد'}
    }, excludedHere: false);
    expect((trading.line, trading.canSwitch), ('لا يدخل: نظير «400 مبيعات ذهب جديد»، والمتاجرة تُقرأ من الفواتير', false));
    final outside = gramProfitSaying({'state': 'outside', 'side': null, 'via': null}, excludedHere: false);
    expect((outside.line, outside.canSwitch), ('لا يدخل: ليس حساب إيراد أو مصروف', false));
    expect(gramProfitSaying(null, excludedHere: false).line, isNull, reason: 'a new account: the rule, no standing');
  });

  testWidgets('a counted account says so, and its switch excludes it when saved', (tester) async {
    final api = await _open(
        tester, _account(5410, '5410', 'رواتب الموظفين', standing: {'state': 'counted', 'side': 'expense', 'via': null}));
    expect(find.text('يدخل في ربح الجرام مصروفًا'), findsOneWidget);
    await tester.tap(find.byKey(const Key('account-form-gram-profit-exclude')));
    await tester.pumpAndSettle();
    expect(find.text('مستثنى من ربح الجرام'), findsOneWidget);
    await tester.tap(find.text('حفظ'));
    await tester.pumpAndSettle();
    expect(api.saved.single['exclude_from_gram_profit'], isTrue);
    expect(api.saved.single.containsKey('include_in_gram_profit'), isFalse, reason: 'the old mark is not written');
  });

  testWidgets('excluded by its parent: said, and put back from there, not here', (tester) async {
    await _open(
        tester,
        _account(590, '590', 'مصروف الزكاة',
            parentId: 59, standing: {'state': 'excluded', 'side': 'expense', 'via': _zakatGroup}));
    expect(find.text('مستثنى، لأن «59 الزكاة» مستثنى'), findsOneWidget);
    expect(find.text('يُعاد من «59 الزكاة»'), findsOneWidget);
    final tile = tester.widget<SwitchListTile>(find.byKey(const Key('account-form-gram-profit-exclude')));
    expect(tile.onChanged, isNull);
  });
}
