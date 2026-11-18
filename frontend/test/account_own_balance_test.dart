// A group's own balance (the owner, 18 Nov 2026): «تحذير بحيث يمكن اضافة
// حساب فرعي ونقل الرصيد اليه». An account put under one with a balance of its
// own says so, with the balance, and offers its move there or later; the
// group's menu moves it to an account under it, chosen -- the server moves
// each entry at its date (services/group_balance).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/widgets/account_management.dart';

const _held = {
  'account_id': 855, 'account_number': '5440', 'name': 'رسوم التراخيص ومخالفات',
  'cash': 28222.21, 'grams': {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0, 'weight': 0.0},
  'entries': 9, 'any': true,
};

class _FakeApi extends ApiService {
  _FakeApi({this.held});
  final Map<String, dynamic>? held;
  final moved = <(int, int)>[];

  @override
  Future<Map<String, dynamic>> validateAccountNumber({
    required String accountNumber,
    required String parentAccountNumber,
    int? excludeAccountId,
  }) async =>
      {'is_valid': true};

  @override
  Future<Map<String, dynamic>> getNextAccountNumber(String parentNumber) async =>
      {'next_number': '5440002', 'parent_has_parallel': false};

  @override
  Future<Map<String, dynamic>> addAccount(Map<String, dynamic> accountData) async => {
        'id': 1400, 'account_number': accountData['account_number'], 'name': accountData['name'],
        if (held != null) 'parent_own_balance': held,
      };

  @override
  Future<Map<String, dynamic>> getAccountById(int accountId) async => {'id': accountId, 'own_balance': held};

  @override
  Future<Map<String, dynamic>> moveGroupOwnBalance(int groupId, int toAccountId) async {
    moved.add((groupId, toAccountId));
    return {'moved': 9, 'entries': [], 'cash': 28222.21};
  }
}

const _group = {'id': 855, 'account_number': '5440', 'name': 'رسوم التراخيص ومخالفات', 'type': 'Expense',
  'parent_id': 839, 'tracks_weight': false};
const _child = {'id': 1179, 'account_number': '5440000', 'name': 'رسوم تجديد رخص العمل', 'type': 'Expense',
  'parent_id': 855, 'tracks_weight': false};

Future<void> _host(WidgetTester tester, Future<bool> Function(BuildContext) open) async {
  await tester.pumpWidget(MaterialApp(
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => open(context), child: const Text('افتح')),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('افتح'));
  await tester.pumpAndSettle();
}

Future<void> _addUnder(WidgetTester tester, _FakeApi api) async {
  await _host(tester, (context) => showAccountForm(context, api: api, accounts: [_group, _child], parent: _group));
  await tester.enterText(find.byKey(const Key('account-form-number')), '5440002');
  await tester.enterText(find.byKey(const Key('account-form-name')), 'رسوم البلدية');
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('account-form-save')));
  await tester.pumpAndSettle();
}

void main() {
  test('the balance is said in words', () {
    expect(ownBalanceWords(_held), '28,222.21 ر.س في 9 قيد');
  });

  testWidgets('put under one with a balance of its own: said, and moved there when asked', (tester) async {
    final api = _FakeApi(held: _held);
    await _addUnder(tester, api);
    expect(find.byKey(const Key('own-balance-offer')), findsOneWidget);
    expect(find.textContaining('28,222.21 ر.س في 9 قيد'), findsOneWidget);
    await tester.tap(find.text('انقل الرصيد'));
    await tester.pumpAndSettle();
    expect(api.moved, [(855, 1400)]);
  });

  testWidgets('«later» moves nothing', (tester) async {
    final api = _FakeApi(held: _held);
    await _addUnder(tester, api);
    await tester.tap(find.text('لاحقًا'));
    await tester.pumpAndSettle();
    expect(api.moved, isEmpty);
  });

  testWidgets('put under one with no balance of its own: nothing is asked', (tester) async {
    final api = _FakeApi();
    await _addUnder(tester, api);
    expect(find.byKey(const Key('own-balance-offer')), findsNothing);
  });

  testWidgets('from the group\'s menu: an account under it chosen, then moved', (tester) async {
    final api = _FakeApi(held: _held);
    await _host(tester, (context) => moveOwnBalanceFlow(context, api: api, account: _group, accounts: [_group, _child]));
    expect(find.byKey(const Key('own-balance-move')), findsOneWidget);
    await tester.enterText(find.byKey(const Key('own-balance-target')), '5440000');
    await tester.pumpAndSettle();
    await tester.tap(find.text('5440000 — رسوم تجديد رخص العمل').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('انقل الرصيد'));
    await tester.pumpAndSettle();
    expect(api.moved, [(855, 1179)]);
  });
}
