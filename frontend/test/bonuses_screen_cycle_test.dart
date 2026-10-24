import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/bonuses_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The bonuses cycle (bonus study م3ب): each act says what it does to the
/// books before it does it, a bonus says why it is its amount, and a bonus its
/// rule computed keeps its rule's amount and period.
class _Api extends ApiService {
  _Api() : super(baseUrl: 'http://test');

  final approved = <int>[];
  final rejected = <(int, String?)>[];
  final paid = <(int, int)>[];
  Map<String, dynamic>? updated;
  List<int>? bulkApproved;

  static Map<String, dynamic> _bonus(int id, String name, String status, double amount,
          {Map<String, dynamic>? rule, Map<String, dynamic>? data}) =>
      {
        'id': id, 'employee_id': id, 'bonus_rule_id': rule == null ? null : 1, 'bonus_type': 'tiers',
        'amount': amount, 'period_start': '2026-09-01', 'period_end': '2026-09-30', 'status': status,
        'calculation_data': data, 'employee': {'name': name, 'employee_code': 'E$id'}, 'bonus_rule': rule,
      };

  static const _rule = {'name': 'الهدف الشهري', 'rule_type': 'tiered'};

  @override
  Future<List<dynamic>> getBonuses({int? employeeId, String? status, String? dateFrom, String? dateTo}) async => [
    _bonus(1, 'مسعد المهري', 'pending', 2912.5, rule: _rule, data: {
      'measure': 'points', 'period': 'monthly', 'value': 1165,
      'tier': {'from': 1000, 'per_unit': 2.5}, 'employee_points': 1165,
    }),
    _bonus(2, 'يوسف الشعبي', 'pending', 300.0),
    _bonus(4, 'خالد الحربي', 'paid', 3000.0, rule: _rule, data: {
      'measure': 'points', 'value': 1200, 'tier': {'from': 1000, 'per_unit': 2.5},
      'measured_from': '2026-09-15', 'measured_to': '2026-09-30',
    }),
    _bonus(3, 'صالح العبادي', 'approved', 500.0, rule: _rule),
  ];

  @override
  Future<Map<String, dynamic>> getBonusesOwed() async => {'employees': []};

  @override
  Future<Map<String, dynamic>> approveBonus(int id) async {
    approved.add(id);
    return {'voucher': {'voucher_number': 'BAPP-$id'}};
  }

  @override
  Future<void> rejectBonus(int id, {String? reason}) async => rejected.add((id, reason));

  @override
  Future<void> updateBonus(int id, Map<String, dynamic> data) async => updated = data;

  @override
  Future<Map<String, dynamic>> bulkApproveBonuses(List<int> ids) async {
    bulkApproved = ids;
    return {
      'approved_count': 1,
      'failed': [{'id': ids.last, 'error': 'لا حساب مكافآت مستحقة للموظف (يوسف الشعبي).'}],
    };
  }

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({String? safeType, bool? isActive, int? karat,
      bool includeAccount = false, bool includeBalance = false}) async => [
    SafeBoxModel.fromJson({'id': 7, 'account_id': 70, 'name': 'الصندوق الرئيسي', 'safe_type': 'cash', 'balance': {'cash': 200.0}}),
    SafeBoxModel.fromJson({'id': 8, 'account_id': 80, 'name': 'بنك الرياض', 'safe_type': 'bank', 'balance': {'cash': 9000.0}}),
  ];

  @override
  Future<void> payBonus(int id, {required int safeBoxId, String paymentMethod = 'cash'}) async =>
      paid.add((id, safeBoxId));
}

Future<_Api> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await initializeDateFormatting('ar');
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api();
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: settings,
    child: MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(textDirection: TextDirection.rtl, child: BonusesScreen(api: api)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

Future<void> _open(WidgetTester tester, String name, String action) async {
  await tester.tap(find.text(name));
  await tester.pumpAndSettle();
  await tester.tap(find.text(action).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a bonus says why it is its amount: its measure, its value, its tier', (tester) async {
    await _pump(tester);
    expect(find.text('النقاط 1,165 · شريحة من 1,000 بـ 2.50 لكل وحدة'), findsOneWidget);
    expect(find.text('النقاط 1,200 · شريحة من 1,000 بـ 2.50 لكل وحدة · عن 2026-09-15 → 2026-09-30'),
        findsOneWidget, reason: 'a rule valid for part of the period says the days it counted');
  });

  testWidgets('approve asks first, says the entry, and then says its number', (tester) async {
    final api = await _pump(tester);
    await _open(tester, 'مسعد المهري', 'اعتماد');
    final effect = tester.widget<Text>(
        find.descendant(of: find.byKey(const Key('confirm-effect')), matching: find.byType(Text)));
    expect(effect.data, contains('النقاط 1,165 · شريحة من 1,000'));
    expect(effect.data, contains('مصروف المكافآت مدين، ومكافآت مسعد المهري المستحقة دائنة'));
    await tester.tap(find.text('تراجع'));
    await tester.pumpAndSettle();
    expect(api.approved, isEmpty, reason: 'going back approves nothing');

    await _open(tester, 'مسعد المهري', 'اعتماد');
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(api.approved, [1]);
    expect(find.text('اعتُمدت، وقيدها BAPP-1'), findsOneWidget);
  });

  testWidgets("a rule's bonus offers only its note, and says why", (tester) async {
    final api = await _pump(tester);
    await _open(tester, 'مسعد المهري', 'تعديل');
    expect(find.byKey(const Key('edit-by-rule')), findsOneWidget);
    expect(find.byKey(const Key('edit-amount')), findsNothing);
    await tester.enterText(find.byKey(const Key('edit-note')), 'راجعها المدير');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(api.updated, {'notes': 'راجعها المدير'}, reason: 'no amount, no period: the rule computes them');
  });

  testWidgets('a manual bonus is the manager\'s: its amount is offered', (tester) async {
    final api = await _pump(tester);
    await _open(tester, 'يوسف الشعبي', 'تعديل');
    expect(find.byKey(const Key('edit-by-rule')), findsNothing);
    await tester.enterText(find.byKey(const Key('edit-amount')), '350');
    await tester.tap(find.byKey(const Key('edit-save')));
    await tester.pumpAndSettle();
    expect(api.updated!['amount'], 350.0);
    expect(api.updated!['period_start'], '2026-09-01');
  });

  testWidgets('reject keeps its reason', (tester) async {
    final api = await _pump(tester);
    await _open(tester, 'يوسف الشعبي', 'رفض');
    await tester.enterText(find.byKey(const Key('reject-reason')), 'مكررة');
    await tester.tap(find.byKey(const Key('reject-confirm')));
    await tester.pumpAndSettle();
    expect(api.rejected, [(2, 'مكررة')]);
  });

  testWidgets('pay says the voucher it makes, and a safe short of the bonus', (tester) async {
    final api = await _pump(tester);
    await _open(tester, 'صالح العبادي', 'صرف');
    final effect = find.descendant(of: find.byKey(const Key('pay-effect')), matching: find.byType(Text));
    expect(tester.widget<Text>(effect).data, contains('أقل من المكافأة'),
        reason: 'the first safe holds 200 against 500');
    await tester.tap(find.byKey(const Key('pay-safe')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('بنك الرياض').last);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(effect).data,
        contains('مكافآت صالح العبادي المستحقة مدينة، وبنك الرياض دائنة'));
    await tester.tap(find.byKey(const Key('pay-confirm')));
    await tester.pumpAndSettle();
    expect(api.paid, [(3, 8)]);
  });

  testWidgets('approve all says how many, how much, for whom -- and a refusal in the server\'s words',
      (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.text('اعتماد الكل'));
    await tester.pumpAndSettle();
    final effect = tester.widget<Text>(
        find.descendant(of: find.byKey(const Key('confirm-effect')), matching: find.byType(Text)));
    expect(effect.data, contains('لـ مسعد المهري، يوسف الشعبي'));
    expect(find.textContaining('3,212.50'), findsWidgets);
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(api.bulkApproved, [1, 2]);
    expect(find.textContaining('اعتُمدت 1، ولم تُعتمد 1: لا حساب مكافآت مستحقة للموظف'), findsOneWidget);
  });
}
