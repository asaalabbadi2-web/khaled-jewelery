// ADR-100: a deposit confirmed by what reached the bank -- the dialog shows
// the server's preview, asks a reason beyond the allowance, and sends the
// settlements chosen, what came and its day.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/deposit_confirm_dialog.dart';

class _Api extends ApiService {
  Map<String, dynamic>? sent;
  double difference = 5.0;

  @override
  Future<Map<String, dynamic>> getUnconfirmedSettlements(int paymentMethodId) async => {
    'settlements': [
      {'voucher_id': 7, 'voucher_number': 'AV-2026-00584', 'date': '2026-11-10', 'net': 917.89},
    ],
  };

  @override
  Future<Map<String, dynamic>> previewClearingDeposit({
    required int paymentMethodId,
    required List<int> voucherIds,
    required double amountReceived,
  }) async => {
    'expected_net': 917.89,
    'amount_received': amountReceived,
    'difference': difference,
    'fee_difference': difference == 0 ? 0 : 4.35,
    'vat_difference': difference == 0 ? 0 : 0.65,
    'allowed_difference': 10.0,
    'note_required': difference.abs() > 10,
  };

  @override
  Future<Map<String, dynamic>> confirmClearingDeposit({
    required int paymentMethodId,
    required List<int> voucherIds,
    required double amountReceived,
    required String depositDate,
    String? bankReference,
    String? note,
  }) async {
    sent = {'ids': voucherIds, 'amount': amountReceived, 'date': depositDate, 'note': note};
    return {'deposit': {'id': 1}};
  }
}

void main() {
  Future<void> open(WidgetTester tester, _Api api) async {
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDepositConfirmDialog(context, api: api, method: {'id': 13, 'name': 'تمارا'}),
              child: const Text('افتح'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('افتح'));
    await tester.pumpAndSettle();
  }

  testWidgets('the server\'s preview, and the settlements, amount and day sent', (tester) async {
    final api = _Api();
    await open(tester, api);
    await tester.tap(find.byKey(const Key('deposit-settlement-7')));
    await tester.enterText(find.byKey(const Key('deposit-amount-received')), '912.89');
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('deposit-preview')), findsOneWidget);
    expect(find.textContaining('4.35'), findsOneWidget);
    await tester.tap(find.byKey(const Key('deposit-confirm')));
    await tester.pumpAndSettle();
    expect(api.sent, {'ids': [7], 'amount': 912.89, 'date': '2026-11-10', 'note': ''});
  });

  testWidgets('beyond the allowance, no confirming without a reason', (tester) async {
    final api = _Api()..difference = 117.89;
    await open(tester, api);
    await tester.tap(find.byKey(const Key('deposit-settlement-7')));
    await tester.enterText(find.byKey(const Key('deposit-amount-received')), '800');
    await tester.pumpAndSettle();
    final button = tester.widget<FilledButton>(find.byKey(const Key('deposit-confirm')));
    expect(button.onPressed, isNull);
    await tester.enterText(find.byKey(const Key('deposit-note')), 'مرتجع خصمته تمارا');
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.byKey(const Key('deposit-confirm'))).onPressed, isNotNull);
  });
}
