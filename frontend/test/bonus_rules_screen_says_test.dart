import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/bonus_rules_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The rules page says each rule as the calculator reads it, and its form
/// offers only what the calculator reads (bonus study م3ج).
class _Api extends ApiService {
  _Api() : super(baseUrl: 'http://test');

  final updates = <(int, Map<String, dynamic>)>[];
  Map<String, dynamic>? created;

  static const _sales = {
    'id': 2, 'name': 'هدف المبيعات', 'rule_type': 'sales_target', 'bonus_type': 'sales_percentage',
    'bonus_value': 1.0, 'min_bonus': 0.0, 'conditions': {'sales_target': 50000, 'min_attendance_rate': 90},
    'target_employee_ids': [16, 17],
    'target_employees': [{'id': 16, 'name': 'مسعد المهري'}, {'id': 17, 'name': 'يوسف الشعبي'}],
    'is_active': true, 'valid_from': '2031-01-01', 'valid_to': '2031-12-31',
  };

  @override
  Future<List<dynamic>> getBonusRules({bool? isActive}) async => [
    _sales,
    {'id': 3, 'name': 'ثابتة للجميع', 'rule_type': 'fixed', 'bonus_type': 'fixed', 'bonus_value': 200.0,
     'min_bonus': 0.0, 'is_active': true},
  ];

  @override
  Future<Map<String, dynamic>> getEmployees({int page = 1, int perPage = 20, String? search,
      String? department, bool? isActive = true, bool showAll = false}) async => {'employees': []};

  @override
  Future<List<dynamic>> getInvoiceTypes() async => ['بيع', 'شراء من عميل'];

  @override
  Future<void> updateBonusRule(int id, Map<String, dynamic> data) async => updates.add((id, data));

  @override
  Future<Map<String, dynamic>> createBonusRule(Map<String, dynamic> data) async => created = data;

  @override
  Future<void> deleteBonusRule(int id) async => throw const ApiException(
        statusCode: 409,
        code: 'rule_in_use',
        message: 'لهذه القاعدة 15 مكافأة. أوقفها بدل حذفها، فتبقى مكافآتها وتاريخها.',
      );
}

Future<_Api> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  tester.view.physicalSize = const Size(1200, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final api = _Api();
  await tester.pumpWidget(ChangeNotifierProvider.value(
    value: settings,
    child: MaterialApp(theme: LightTheme.theme, home: BonusRulesScreen(api: api)),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('a rule says its employees by name, its target and its validity', (tester) async {
    await _pump(tester);
    await tester.tap(find.text('هدف المبيعات').first);
    await tester.pumpAndSettle();
    expect(find.text('مسعد المهري، يوسف الشعبي'), findsOneWidget);
    expect(find.textContaining('50,000'), findsOneWidget);
    expect(find.text('من 2031-01-01 إلى 2031-12-31'), findsOneWidget);
    await tester.tap(find.text('ثابتة للجميع'));
    await tester.pumpAndSettle();
    expect(find.text('كل الموظفين'), findsOneWidget);
  });

  testWidgets('a rule in use is not deleted: the refusal offers to stop it', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.text('هدف المبيعات').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rule-delete-2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(find.textContaining('أوقفها بدل حذفها'), findsOneWidget);
    await tester.tap(find.widgetWithText(SnackBarAction, 'أوقفها'));
    await tester.pumpAndSettle();
    final (id, sent) = api.updates.single;
    expect(id, 2);
    expect(sent, {'is_active': false});
  });

  testWidgets("a sales rule's form offers its target and its own payouts, and drops what nothing read",
      (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.text('هدف المبيعات').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.edit).first);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('rule-sales-target')), findsOneWidget);
    expect(find.text('نسبة حضور %'), findsNothing);
    expect(find.text('حد أدنى للمبيعات'), findsNothing);
    expect(find.text('أنواع الفواتير'), findsNothing, reason: 'a sales rule reads none');
    await tester.tap(find.byKey(const Key('rule-payout')));
    await tester.pumpAndSettle();
    expect(find.text('نسبة من الربح'), findsNothing, reason: 'a sales rule pays no profit percentage');
    await tester.tap(find.text('نسبة من المبيعات').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('rule-sales-target')), '60000');
    await tester.tap(find.byTooltip('مسح').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rule-save')));
    await tester.pumpAndSettle();
    final (id, sent) = api.updates.single;
    expect(id, 2);
    expect(sent['conditions'], {'sales_target': 60000.0}, reason: 'the attendance rate nothing read is gone');
    expect(sent['valid_from'], isNull, reason: 'a validity cleared is sent cleared');
    expect(sent['valid_to'], '2031-12-31');
    expect(sent.containsKey('applicable_invoice_types'), isFalse);
  });

  testWidgets('a profit rule offers invoice types: it is the one that reads them', (tester) async {
    final api = await _pump(tester);
    await tester.tap(find.text('إضافة قاعدة'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextFormField, 'الاسم'), 'ربح');
    await tester.tap(find.text('شرائح').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('على أساس الربح').last);
    await tester.pumpAndSettle();
    expect(find.text('أنواع الفواتير'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilterChip, 'بيع'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('rule-save')));
    await tester.pumpAndSettle();
    expect(api.created!['applicable_invoice_types'], ['بيع']);
    expect(api.created!['conditions'], {'min_profit': 0.0, 'profit_type': 'cash'});
  });
}
