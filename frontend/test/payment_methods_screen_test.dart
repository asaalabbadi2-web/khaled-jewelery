// The payment methods screen and its form (the owner, 24 Nov 2026: «شاشة
// وسائل الدفع وديالوجاتها تحتاج تطوير من حيث الشكل، الألوان والتباين ودعم
// الشاشات الصغيرة والكبيرة»). Before: in the dark the settlement section was a
// white block of near-white text; the form overflowed a phone by 334 pixels;
// a wide screen showed three methods a card each; «رقم الحساب: غير محدد» on
// every method; the commissions in the warning's orange. Now: a table on a wide
// screen, cards on a phone, the form a whole page on a phone and an index of
// its sections on a wide one -- nothing overflows, nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/payment_methods_screen_enhanced.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';

Map<String, dynamic> _m(int id, String type, String name, double rate,
        {double fixed = 0, bool auto = false, int box = 30, List<Map<String, dynamic>> plans = const [],
        double depositFee = 0, bool confirm = false}) =>
    {
      'id': id, 'payment_type': type, 'name': name, 'commission_rate': rate, 'commission_fixed_amount': fixed,
      'settlement_days': 0, 'auto_settlement_enabled': auto, 'settlement_schedule_type': 'days',
      'deposit_delay_days': 1, 'deposit_schedule_type': 'days', 'bank_weekend_days': '',
      'skip_public_holidays': false, 'schedule_summary': auto ? 'يومية: تُودَع بعد يوم' : null,
      'settlement_bank_safe_box_id': auto ? 37 : null, 'fee_expense_account_id': null,
      'min_settlement_amount': 0.0, 'settlement_mode': 'bulk', 'deposit_fixed_fee': depositFee,
      'commission_per_order': plans.isNotEmpty, 'deposit_confirmation_required': confirm,
      'commission_rounding': 'half_up', 'commission_refundable_rate': 0.0, 'deposit_difference_allowed': 10.0,
      'plans': plans, 'is_active': true, 'display_order': id,
      'applicable_invoice_types': ['بيع', 'مرتجع بيع'], 'default_safe_box_id': box,
      'default_safe_box': {'id': box, 'name': name, 'safe_type': 'clearing', 'account_id': 1},
    };

class _Api extends ApiService {
  final updates = <Map<String, dynamic>>[];
  final deleted = <int>[];

  @override
  Future<List<dynamic>> getPaymentMethods({String? invoiceType}) async => [
    _m(9, 'cash', 'نقداً', 0, box: 38),
    _m(10, 'mada', 'مدى', 0.8, auto: true, box: 32),
    _m(13, 'tamara', 'تمارا', 6.99, fixed: 1.5, auto: true, box: 35, confirm: true, plans: [
      for (final (n, r) in [(2, 6.99), (3, 6.99), (4, 6.99), (6, 5.99), (9, 5.99), (12, 5.99)])
        {'installments': n, 'commission_rate': r},
    ]),
    _m(12, 'tabby', 'تابي', 6.99, fixed: 1.5, auto: true, box: 34, depositFee: 6, confirm: true),
  ];

  @override
  Future<List<dynamic>> getPaymentTypes() async => [
    {'code': 'cash', 'name_ar': 'نقدي'}, {'code': 'mada', 'name_ar': 'بطاقة مدى'},
    {'code': 'tabby', 'name_ar': 'تابي'}, {'code': 'tamara', 'name_ar': 'تمارا'},
  ];

  @override
  Future<Map<String, dynamic>> getPaymentInvoiceTypeOptions() async => {
    'options': [{'value': 'بيع', 'name_ar': 'بيع'}, {'value': 'مرتجع بيع', 'name_ar': 'مرتجع بيع'}],
  };

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({String? safeType, bool? isActive, int? karat,
      bool includeAccount = false, bool includeBalance = false}) async => [
    SafeBoxModel(id: 35, name: 'تمارا', safeType: 'clearing', accountId: 35),
    SafeBoxModel(id: 37, name: 'بنك الرياض', safeType: 'bank', accountId: 37),
  ];

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [];

  @override
  Future<Map<String, dynamic>> previewPaymentMethodSchedule(Map<String, dynamic> schedule) async =>
      {'summary': 'يومية', 'rows': []};

  @override
  Future<Map<String, dynamic>> updatePaymentMethod(int id, {required String paymentType, required String name,
      required double commissionRate, double? commissionFixedAmount, int settlementDays = 0,
      bool? autoSettlementEnabled, String? settlementScheduleType, int? settlementWeekday,
      int? settlementBankSafeBoxId, int? feeExpenseAccountId, double minSettlementAmount = 0.0,
      String settlementMode = 'bulk', int depositDelayDays = 0, String depositScheduleType = 'days',
      int? depositWeekday, List<int>? bankWeekendDays, bool? skipPublicHolidays, required bool isActive,
      int? defaultSafeBoxId, List<String>? applicableInvoiceTypes, double? depositFixedFee,
      bool? commissionPerOrder, List<Map<String, dynamic>>? plans, bool? depositConfirmationRequired,
      double? depositDifferenceAllowed, String? commissionRounding, double? commissionRefundableRate,
      String? taxInvoiceFrom}) async {
    updates.add({'id': id, 'name': name, 'rate': commissionRate, 'plans': plans, 'bank': settlementBankSafeBoxId,
        'confirm': depositConfirmationRequired, 'tax_invoice_from': taxInvoiceFrom});
    return {};
  }

  @override
  Future<Map<String, dynamic>> deletePaymentMethod(int id) async {
    deleted.add(id);
    return {'message': 'حُذفت'};
  }
}

const _sizes = {'wide': Size(1600, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<_Api> open(WidgetTester tester, Size size, {bool dark = false}) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(ChangeNotifierProvider(
      create: (_) => SettingsProvider(),
      child: MaterialApp(
        theme: dark ? DarkTheme.theme : LightTheme.theme,
        builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
        home: PaymentMethodsScreenEnhanced(apiService: api),
      ),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> openForm(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.byKey(const Key('pm-menu-13')), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byKey(const Key('pm-menu-13')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('تعديل').last);
    await tester.pumpAndSettle();
  }

  /// Scrolls the form's sections through, checking each view.
  Future<void> throughTheForm(WidgetTester tester, void Function() check) async {
    final body = find.descendant(of: find.byType(Dialog), matching: find.byType(SingleChildScrollView)).first;
    for (var i = 0; i < 8; i++) {
      check();
      await tester.drag(body, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the list and the form fit and read', (tester) async {
        await open(tester, size, dark: dark);
        expect(tester.takeException(), isNull, reason: 'the list overflows');
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await openForm(tester);
        expect(tester.takeException(), isNull, reason: 'the form overflows');
        await throughTheForm(tester, () {
          expect(tester.takeException(), isNull);
          if (dark) {
            expectNoTextVanishesOnDark(tester, within: find.byType(Dialog));
            // The settlement section was a white block of near-white text.
            expectNoLightSurfaceOnDark(tester);
          }
        });
      });
    }
  }

  testWidgets('a wide screen: a table, a row a method -- no «رقم الحساب: غير محدد», its plans by rate',
      (tester) async {
    await open(tester, _sizes['wide']!);
    expect(find.byKey(const Key('app-table')), findsOneWidget);
    expect(find.byKey(const Key('pm-row-13')), findsOneWidget);
    expect(find.textContaining('رقم الحساب'), findsNothing);
    expect(find.textContaining('2، 3، 4 دفعات'), findsOneWidget);
    expect(find.textContaining('6، 9، 12 دفعة'), findsOneWidget);
    expect(find.textContaining('لكل إيداع'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing, reason: 'the add is in the bar, covering nothing');
    expect(find.byKey(const Key('pm-add')), findsOneWidget);
  });

  testWidgets('a phone: cards, not a table', (tester) async {
    await open(tester, _sizes['phone']!);
    expect(find.byKey(const Key('app-table')), findsNothing);
    expect(find.byKey(const Key('pm-card-9')), findsOneWidget);
  });

  testWidgets('the form: a whole page on a phone, an index of its sections on a wide screen', (tester) async {
    await open(tester, _sizes['phone']!);
    await openForm(tester);
    expect(find.byKey(const Key('pm-form-go-fees')), findsNothing);
    expect(find.descendant(of: find.byType(Dialog), matching: find.byType(AppBar)), findsOneWidget);
    await tester.tap(find.byTooltip('إغلاق'));
    await tester.pumpAndSettle();

    await open(tester, _sizes['wide']!);
    await openForm(tester);
    expect(find.byKey(const Key('pm-form-go-fees')), findsOneWidget);
    await tester.tap(find.byKey(const Key('pm-form-go-invoices')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pm-form-all-invoices')).hitTestable(), findsOneWidget);
  });

  testWidgets('saving sends what the form holds', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await openForm(tester);
    await tester.enterText(find.byKey(const Key('pm-form-name')), 'تمارا الجديدة');
    await tester.tap(find.byKey(const Key('pm-form-save')));
    await tester.pumpAndSettle();
    expect(api.updates.single['name'], 'تمارا الجديدة');
    expect((api.updates.single['plans'] as List).length, 6);
    expect(api.updates.single['bank'], 37);
    expect(api.updates.single['confirm'], isTrue);
    expect(find.byType(Dialog), findsNothing);
  });

  // The owner, 25 Nov 2026: «ألا يجب ألا يجتمع عمولة بنسبة ثابتة مع عمولة
  // متغيرة حسب الخطط؟» -- «يُخفى ويُحفظ صفرًا»: Tamara's old 6.99 beside its plans.
  testWidgets('beside plans there is no single rate: it is not shown, and is saved as nothing', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await openForm(tester);
    expect(find.byKey(const Key('pm-form-rate')), findsNothing);
    expect(find.byKey(const Key('pm-form-rate-by-plans')), findsOneWidget);
    expect(find.byKey(const Key('pm-form-fixed')), findsOneWidget, reason: 'the fixed amount an order stays');
    await tester.tap(find.byKey(const Key('pm-form-save')));
    await tester.pumpAndSettle();
    expect(api.updates.single['rate'], 0.0);
  });

  testWidgets('a deletion is asked first, then sent', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await tester.tap(find.byKey(const Key('pm-menu-12')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('حذف').last);
    await tester.pumpAndSettle();
    expect(api.deleted, isEmpty);
    await tester.tap(find.byKey(const Key('pm-delete-confirm')));
    await tester.pumpAndSettle();
    expect(api.deleted, [12]);
  });
}
