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

/// PAY-ORDER-1 (the owner, 8 Oct 2026): «where is the order of the payment
/// methods set?» Nowhere: the order was stored and the server could save it,
/// but no screen set it. The payment methods screen sets it now, and the
/// invoice screens show their pay buttons in it.
class _FakeApi extends ApiService {
  _FakeApi(this.methods);

  List<Map<String, dynamic>> methods;
  final saved = <List<int>>[];

  @override
  Future<List<dynamic>> getPaymentMethods({String? invoiceType}) async =>
      methods;

  @override
  Future<List<dynamic>> getPaymentTypes() async => [];

  @override
  Future<Map<String, dynamic>> getPaymentInvoiceTypeOptions() async => {};

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => [];

  @override
  Future<List<dynamic>> getAccounts({bool skipBalances = false}) async => [];

  @override
  Future<void> updatePaymentMethodsOrder(
    List<Map<String, dynamic>> methods,
  ) async {
    saved.add([for (final m in methods) m['id'] as int]);
  }
}

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Map<String, dynamic> method(int id, String name, int order) => {
    'id': id,
    'name': name,
    'payment_type': 'cash',
    'commission_rate': 0.0,
    'is_active': true,
    'display_order': order,
    'applicable_invoice_types': <String>[],
  };

  Future<_FakeApi> open(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _FakeApi([
      method(14, 'تحويل', 1),
      method(9, 'نقداً', 2),
      method(10, 'مدى', 3),
    ]);
    await tester.pumpWidget(
      ChangeNotifierProvider(
        create: (_) => SettingsProvider(),
        child: MaterialApp(
          theme: LightTheme.theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: PaymentMethodsScreenEnhanced(apiService: api),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  testWidgets('a method is moved up, and the order is saved', (tester) async {
    final api = await open(tester);

    await tester.tap(find.byKey(const Key('order-up-9')));
    await tester.pumpAndSettle();

    expect(api.saved.single, [9, 14, 10]);
  });

  testWidgets('a method is moved down, and the order is saved', (tester) async {
    final api = await open(tester);

    await tester.tap(find.byKey(const Key('order-down-14')));
    await tester.pumpAndSettle();

    expect(api.saved.single, [9, 14, 10]);
  });

  testWidgets('the first cannot go up, nor the last down', (tester) async {
    await open(tester);

    final up = tester.widget<IconButton>(find.byKey(const Key('order-up-14')));
    final down = tester.widget<IconButton>(
      find.byKey(const Key('order-down-10')),
    );
    expect(up.onPressed, isNull);
    expect(down.onPressed, isNull);
  });

  testWidgets('each method says its place', (tester) async {
    await open(tester);
    expect(find.text('الترتيب 1'), findsOneWidget);
    expect(find.text('الترتيب 3'), findsOneWidget);
  });
}
