// A commission's VAT waits for its monthly tax invoice (ADR-101, the owner 25
// Nov 2026: «الفواتير الضريبية»). The months of a method that issues them: a
// table on a wide screen, cards on a phone; each its orders and what they
// compute to (the server's), its invoice or that it waits. An invoice entered
// is the server's checked figures; one cancelled is its voucher's cancel.
// The method's settings say the month its invoices start from. Nothing
// overflows; nothing vanishes in the dark.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/commission_tax_invoices_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/date_field.dart';
import 'package:frontend/widgets/payment_plans_editor.dart';

import 'support/dark_text.dart';

class _Api extends ApiService {
  final previews = <Map<String, dynamic>>[];
  final entered = <Map<String, dynamic>>[];
  final cancelled = <(int, String)>[];
  int loads = 0;

  @override
  Future<Map<String, dynamic>> getCommissionTaxInvoices(int paymentMethodId) async {
    loads++;
    return {
      'payment_method_id': paymentMethodId,
      'payment_method_name': 'تمارا',
      'tax_invoice_from': '2026-10-01',
      'pending_vat': 214.99,
      'still_waiting': 214.99,
      'months': [
        {'month': '2026-11', 'orders': 13, 'deposits': 3, 'computed_fee': 2193.78, 'computed_vat': 329.08,
         'state': 'open', 'invoice': null, 'vat_difference': null},
        {'month': '2026-10', 'orders': 10, 'deposits': 4, 'computed_fee': 2658.20, 'computed_vat': 398.73,
         'state': 'invoiced', 'vat_difference': 5.46,
         'invoice': {'id': 1, 'month': '2026-10', 'invoice_number': '92819528', 'invoice_date': '2026-11-01',
                     'supplier_tax_number': '310534637100003', 'fee_amount': 2694.62, 'vat_amount': 404.19,
                     'voucher_id': 77}},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> previewCommissionTaxInvoice(Map<String, dynamic> invoice) async {
    previews.add(invoice);
    return {
      ...invoice, 'orders': 13, 'computed_fee': 2193.78, 'computed_vat': 329.08,
      'fee_difference': 0.02, 'vat_difference': 0.0, 'rounding_moved': -0.12,
    };
  }

  @override
  Future<Map<String, dynamic>> enterCommissionTaxInvoice(Map<String, dynamic> invoice) async {
    entered.add(invoice);
    return {'invoice': {...invoice, 'id': 2}};
  }

  @override
  Future<Map<String, dynamic>> cancelVoucher(int voucherId, String reason) async {
    cancelled.add((voucherId, reason));
    return {'success': true};
  }
}

const _sizes = {'wide': Size(1600, 1000), 'tablet': Size(820, 1180), 'phone': Size(390, 860)};
const _method = {'id': 13, 'name': 'تمارا', 'tax_invoice_from': '2026-10-01'};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<_Api> open(WidgetTester tester, Size size, {bool dark = false}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(MaterialApp(
      theme: dark ? DarkTheme.theme : LightTheme.theme,
      builder: (context, child) => Directionality(textDirection: TextDirection.rtl, child: child!),
      home: CommissionTaxInvoicesScreen(api: api, method: Map<String, dynamic>.from(_method)),
    ));
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> fill(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('tax-invoice-enter-2026-11')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tax-invoice-number')), 'TI-1101');
    await tester.enterText(
        find.descendant(of: find.byType(DateField), matching: find.byType(EditableText)), '2026-12-01');
    await tester.enterText(find.byKey(const Key('tax-invoice-fee')), '2193.80');
    await tester.enterText(find.byKey(const Key('tax-invoice-vat')), '329.07');
    await tester.pumpAndSettle();
  }

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    for (final dark in [false, true]) {
      testWidgets('$name, ${dark ? 'dark' : 'light'}: the months and the invoice fit and read', (tester) async {
        await open(tester, size, dark: dark);
        expect(tester.takeException(), isNull, reason: 'the months overflow');
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
        await fill(tester);
        expect(find.byKey(const Key('tax-invoice-preview')), findsOneWidget);
        expect(tester.takeException(), isNull, reason: 'the invoice overflows');
        if (dark) {
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        }
      });
    }
  }

  testWidgets('a wide screen is a table, a phone cards', (tester) async {
    await open(tester, _sizes['wide']!);
    expect(find.byKey(const Key('app-table')), findsOneWidget);
    expect(find.byKey(const Key('tax-invoice-row-2026-10')), findsOneWidget);
    expect(find.text('أكتوبر 2026'), findsOneWidget);
    expect(find.text('مُدخلة'), findsOneWidget);
    await open(tester, _sizes['phone']!);
    expect(find.byKey(const Key('app-table')), findsNothing);
    expect(find.byKey(const Key('tax-invoice-card-2026-11')), findsOneWidget);
  });

  testWidgets('an invoice entered: the server previews it, and its figures are sent as typed', (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await fill(tester);
    expect(api.previews.last['month'], '2026-11');
    expect(find.textContaining('من العمولة إلى الضريبة'), findsOneWidget, reason: "the server's rounding said");
    await tester.tap(find.byKey(const Key('tax-invoice-save')));
    await tester.pumpAndSettle();
    final sent = api.entered.single;
    expect(sent['payment_method_id'], 13);
    expect(sent['invoice_number'], 'TI-1101');
    expect(sent['invoice_date'], '2026-12-01');
    expect(sent['supplier_tax_number'], '310534637100003', reason: 'the last invoice\'s VAT number to start from');
    expect((sent['fee_amount'], sent['vat_amount']), (2193.80, 329.07));
    expect(api.loads, 2, reason: 'the months read again');
  });

  testWidgets("an invoice cancelled is its voucher's cancel", (tester) async {
    final api = await open(tester, _sizes['wide']!);
    await tester.tap(find.byKey(const Key('tax-invoice-cancel-2026-10')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tax-invoice-cancel-reason')), 'رقم خاطئ');
    await tester.tap(find.byKey(const Key('tax-invoice-cancel-confirm')));
    await tester.pumpAndSettle();
    expect(api.cancelled.single, (77, 'رقم خاطئ'));
  });

  test('a month said by its name', () {
    expect(monthLabel('2026-10'), 'أكتوبر 2026');
    expect(monthLabel('2027-01'), 'يناير 2027');
  });

  testWidgets('the method says the month its invoices start from', (tester) async {
    PaymentFeeTerms? terms;
    await tester.pumpWidget(MaterialApp(
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SingleChildScrollView(
            child: PaymentPlansEditor(
              initial: PaymentFeeTerms.fromMethod(const {'tax_invoice_from': null}),
              onChanged: (t) => terms = t,
            ),
          ),
        ),
      ),
    ));
    expect(find.byKey(const Key('payment-method-tax-invoice-from')), findsNothing);
    await tester.tap(find.byKey(const Key('payment-method-tax-invoices')));
    await tester.pumpAndSettle();
    expect(terms!.error, isNotNull, reason: 'on, its month is asked');
    await tester.enterText(find.byKey(const Key('payment-method-tax-invoice-from')), '2026-10');
    await tester.pumpAndSettle();
    expect(terms!.error, isNull);
    expect(terms!.taxInvoiceFromJson, '2026-10-01');
    await tester.tap(find.byKey(const Key('payment-method-tax-invoices')));
    await tester.pumpAndSettle();
    expect(terms!.taxInvoiceFromJson, '', reason: 'off: it issues none');

    final set = PaymentFeeTerms.fromMethod(const {'tax_invoice_from': '2026-10-01'});
    expect((set.taxInvoices, set.taxInvoiceFrom), (true, '2026-10'));
  });
}
