import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:frontend/api_service.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/screens/accounting_mapping_screen_enhanced.dart';

/// MAPPING-UI-1: «الربط المحاسبي» يرسم أدوار الخادم كما هي -- لا قائمة أدوار
/// في الشاشة -- ويُظهر غير المربوط والموروث والتوأم الناقص، ويعرض رفض الخادم
/// بنصّه، ولا يغيّر شيئًا لمن ليست له الصلاحية.

class _FakeAuth extends AuthProvider {
  _FakeAuth(this.granted);
  final Set<String> granted;

  @override
  bool hasPermission(String key) => granted.contains(key);
}

Map<String, dynamic> _acc(int id, String number, String name, {Map<String, dynamic>? twin}) =>
    {'id': id, 'number': number, 'name': name, 'tracks_weight': false, 'is_active': true, 'twin': twin};

/// ما يرسله الخادم في `/accounting-roles`، ثابتًا.
Map<String, dynamic> _catalog() => {
      'groups': ['الصندوق والضرائب', 'مخزون الذهب وتكلفته'],
      'summary': {'required': 3, 'required_mapped': 2},
      'roles': [
        {
          'key': 'cash', 'label': 'الصندوق', 'group': 'الصندوق والضرائب',
          'purpose': 'الصندوق الافتراضي.', 'kind': 'cash', 'needs_twin': false,
          'retired': false, 'required': true, 'overridable': ['مرتجع بيع'],
          'operations': [
            {'operation': 'افتراضي', 'required': true, 'mapping_id': 1,
             'account': _acc(10, '1100', 'الصندوق الرئيسي'), 'source': 'explicit'},
            {'operation': 'بيع', 'required': true, 'mapping_id': null,
             'account': _acc(10, '1100', 'الصندوق الرئيسي'), 'source': 'default'},
          ],
        },
        {
          'key': 'sales_gold_new', 'label': 'مبيعات ذهب جديد', 'group': 'الصندوق والضرائب',
          'purpose': 'إيراد بيع الذهب الجديد.', 'kind': 'cash', 'needs_twin': false,
          'retired': false, 'required': true, 'overridable': [],
          'operations': [
            {'operation': 'افتراضي', 'required': false, 'mapping_id': null, 'account': null, 'source': null},
            {'operation': 'بيع', 'required': true, 'mapping_id': null,
             'account': _acc(11, '4100', 'إيرادات المبيعات'), 'source': 'alias',
             'via': {'role': 'revenue', 'label': 'الإيرادات', 'operation': 'بيع'}},
          ],
        },
        {
          'key': 'gold_inventory_new', 'label': 'مخزون الذهب الجديد', 'group': 'مخزون الذهب وتكلفته',
          'purpose': 'قيمة الذهب الجديد.', 'kind': 'cash', 'needs_twin': true,
          'retired': false, 'required': true, 'overridable': [],
          'operations': [
            {'operation': 'افتراضي', 'required': true, 'mapping_id': null, 'account': null, 'source': null},
          ],
        },
        {
          'key': 'manufacturing_wage_inventory', 'label': 'أجور مرسملة', 'group': 'مخزون الذهب وتكلفته',
          'purpose': 'تُرسمل فيه الأجور.', 'kind': 'cash', 'needs_twin': true,
          'retired': false, 'required': false, 'overridable': [],
          'operations': [
            {'operation': 'افتراضي', 'required': false, 'mapping_id': 3,
             'account': _acc(30, '1340', 'أجور مرسملة'), 'source': 'explicit'},
            {'operation': 'شراء', 'required': true, 'mapping_id': 5,
             'account': _acc(31, '1341', 'أجور مرسملة للشراء'), 'source': 'explicit'},
          ],
        },
        {
          'key': 'inventory_21k', 'label': 'مخزون عيار 21 (قديم)', 'group': 'مخزون الذهب وتكلفته',
          'purpose': 'لم يعد يطلبه الكود.', 'kind': 'weight', 'needs_twin': false,
          'retired': true, 'required': false, 'overridable': [],
          'operations': [
            {'operation': 'افتراضي', 'required': false, 'mapping_id': 4,
             'account': _acc(40, '71321', 'مخزون 21 وزني'), 'source': 'explicit'},
          ],
        },
      ],
    };

class _FakeApi extends ApiService {
  _FakeApi({this.deleteRefusal}) : super(baseUrl: 'http://test');

  final ApiException? deleteRefusal;
  final List<String> calls = [];

  @override
  Future<Map<String, dynamic>> getAccountingRoles() async {
    calls.add('roles');
    return _catalog();
  }

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [
        {'id': 99, 'account_number': '1110000', 'name': 'بنك الرياض', 'tracks_weight': false, 'is_active': true},
        {'id': 98, 'account_number': '71110000', 'name': 'بنك الرياض وزني', 'tracks_weight': true, 'is_active': true},
      ];

  @override
  Future<Map<String, dynamic>> createAccountingMapping({
    required String operationType,
    required String accountType,
    required int accountId,
  }) async {
    calls.add('create $operationType $accountType $accountId');
    return {'status': 'success'};
  }

  @override
  Future<void> deleteAccountingMapping(int mappingId) async {
    calls.add('delete $mappingId');
    if (deleteRefusal != null) throw deleteRefusal!;
  }
}

Future<void> _pump(WidgetTester tester, _FakeApi api, Set<String> permissions) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider<AuthProvider>.value(
      value: _FakeAuth(permissions),
      child: MaterialApp(home: AccountingMappingScreenEnhanced(api: api)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the roles are the server\'s, with what is unmapped, inherited and twinless', (tester) async {
    await _pump(tester, _FakeApi(), {'accounting.mapping'});

    expect(find.text('الأدوار المطلوبة: 2 من 3 مربوطة'), findsOneWidget);
    for (final label in ['الصندوق', 'مخزون الذهب الجديد', 'أجور مرسملة', 'مخزون عيار 21 (قديم)']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(find.text('غير مربوط'), findsOneWidget);
    expect(find.text('بلا حساب (لا يطلبه النظام هنا)'), findsOneWidget);
    expect(find.text('تأخذ حساب «افتراضي»: بيع'), findsOneWidget);
    expect(find.text('من ربط «الإيرادات»'), findsOneWidget);
    expect(find.text('بلا توأم وزني مربوط'), findsNWidgets(2));
    expect(find.text('لم يعد مستعملًا'), findsOneWidget);
    expect(find.text('حساب خاص لعملية'), findsOneWidget);
  });

  testWidgets('«غير المربوط» shows only the roles a posting would be refused for', (tester) async {
    await _pump(tester, _FakeApi(), {'accounting.mapping'});

    await tester.tap(find.text('غير المربوط (1)'));
    await tester.pumpAndSettle();
    expect(find.text('مخزون الذهب الجديد'), findsOneWidget);
    expect(find.text('الصندوق'), findsNothing);

    await tester.tap(find.text('بلا توأم وزني (1)'));
    await tester.pumpAndSettle();
    expect(find.text('أجور مرسملة'), findsOneWidget);
    expect(find.text('مخزون الذهب الجديد'), findsNothing);
  });

  testWidgets('the search finds a role by its account number', (tester) async {
    await _pump(tester, _FakeApi(), {'accounting.mapping'});

    await tester.enterText(find.byType(TextField), '71321');
    await tester.pumpAndSettle();
    expect(find.text('مخزون عيار 21 (قديم)'), findsOneWidget);
    expect(find.text('الصندوق'), findsNothing);
  });

  testWidgets('without the permission it is shown and not changed', (tester) async {
    await _pump(tester, _FakeApi(), {'business.setup'});

    expect(find.byKey(const ValueKey('mapping-read-only')), findsOneWidget);
    expect(find.byTooltip('تغيير الحساب'), findsNothing);
    expect(find.byTooltip('حذف الربط'), findsNothing);
    expect(find.text('حساب خاص لعملية'), findsNothing);
  });

  testWidgets('a live role\'s default is changed, never removed; a retired one is removed, not changed',
      (tester) async {
    await _pump(tester, _FakeApi(), {'accounting.mapping'});

    final cash = find.byKey(const ValueKey('role-cash'));
    expect(find.descendant(of: cash, matching: find.byTooltip('حذف الربط')), findsNothing);
    expect(find.descendant(of: cash, matching: find.byTooltip('تغيير الحساب')), findsOneWidget);

    final wages = find.byKey(const ValueKey('role-manufacturing_wage_inventory'));
    expect(find.descendant(of: wages, matching: find.byTooltip('حذف الربط')), findsOneWidget,
        reason: 'only the operation\'s own row, not the default');

    final retired = find.byKey(const ValueKey('role-inventory_21k'));
    expect(find.descendant(of: retired, matching: find.byTooltip('تغيير الحساب')), findsNothing);
    expect(find.descendant(of: retired, matching: find.byTooltip('حذف الربط')), findsOneWidget);
  });

  testWidgets('the server\'s refusal is shown in its words', (tester) async {
    final api = _FakeApi(
      deleteRefusal: const ApiException(
          statusCode: 400, code: 'REQUIRED_ROLE', message: '«أجور مرسملة» مطلوب: يُغيَّر حسابه ولا يُحذف ربطه'),
    );
    await _pump(tester, api, {'accounting.mapping'});

    final wages = find.byKey(const ValueKey('role-manufacturing_wage_inventory'));
    await tester.tap(find.descendant(of: wages, matching: find.byTooltip('حذف الربط')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حذف'));
    await tester.pumpAndSettle();

    expect(api.calls, contains('delete 5'));
    expect(find.text('لم يُحفظ'), findsOneWidget);
    expect(find.text('«أجور مرسملة» مطلوب: يُغيَّر حسابه ولا يُحذف ربطه'), findsOneWidget);
  });

  testWidgets('an operation of its own: the dialog says what it takes now, the server is sent the choice',
      (tester) async {
    final api = _FakeApi();
    await _pump(tester, api, {'accounting.mapping'});

    await tester.tap(find.text('حساب خاص لعملية'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('مرتجع بيع'));
    await tester.pumpAndSettle();
    // A cash role is offered cash accounts only.
    expect(find.textContaining('71110000'), findsNothing);
    await tester.tap(find.textContaining('1110000').first);
    await tester.pumpAndSettle();

    expect(find.text('الحالي: 1100 — الصندوق الرئيسي (من «افتراضي»)'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('create مرتجع بيع cash 99'));
  });

  // The owner (23 Oct 2026): «إيراد غير الذهب في التجديد اردت ربطه ب 7430
  // ولكنه لا يظهر لي». A weight role takes weight accounts; the picker hid a
  // leaf weight twin behind its financial side -- which a weight role never
  // shows -- so no paired weight account could be picked.
  testWidgets('a weight role is offered the weight twin of a financial account', (tester) async {
    final api = _WeightRoleApi();
    await _pump(tester, api, {'accounting.mapping'});

    final role = find.byKey(const ValueKey('role-renewal_stones_revenue'));
    await tester.tap(find.descendant(of: role, matching: find.byTooltip('تغيير الحساب')));
    await tester.pumpAndSettle();
    expect(find.textContaining('7430'), findsOneWidget);
    expect(find.textContaining('احجار وفصوص التجديد —'), findsNothing,
        reason: 'not the financial side: a weight role takes weight accounts');
    await tester.tap(find.textContaining('7430'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'حفظ'));
    await tester.pumpAndSettle();
    expect(api.calls, contains('create افتراضي renewal_stones_revenue 1174'));
  });
}

class _WeightRoleApi extends _FakeApi {
  @override
  Future<Map<String, dynamic>> getAccountingRoles() async => {
        'groups': ['مخزون الذهب وتكلفته'],
        'summary': {'required': 0, 'required_mapped': 0},
        'roles': [
          {
            'key': 'renewal_stones_revenue', 'label': 'إيراد غير الذهب في التجديد',
            'group': 'مخزون الذهب وتكلفته', 'purpose': 'وزنًا.', 'kind': 'weight',
            'needs_twin': false, 'retired': false, 'required': false, 'overridable': [],
            'operations': [
              {'operation': 'افتراضي', 'required': false, 'mapping_id': null, 'account': null, 'source': null},
            ],
          },
        ],
      };

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [
        {'id': 1173, 'account_number': '430', 'name': 'احجار وفصوص التجديد', 'tracks_weight': false,
         'is_active': true, 'memo_account_id': 1174},
        {'id': 1174, 'account_number': '7430', 'name': 'احجار وفصوص التجديد وزني', 'tracks_weight': true,
         'is_active': true},
      ];
}
