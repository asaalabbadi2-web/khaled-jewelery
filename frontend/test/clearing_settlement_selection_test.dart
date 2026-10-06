import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/clearing_settlement_screen.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_clearing_api.dart';

/// CLEARING-SEL-1: a settlement settles the payments chosen for it.
///
/// Production, 6 Oct 2026: from the clearing monitor the owner settled Mada
/// payment 3526 (330.00, SELL-2026-1596), then 3527 (90.00). The settlement
/// screen sent every pending payment of the box instead of the selection, the
/// server settled them oldest-first, and both amounts landed on 3520 (3,050.00,
/// SELL-2026-1593): the screen then showed 2,630 + 330 + 90 for what was one
/// payment of 3,050 left. (AV-2026-00472 / 00473.)
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<FakeClearingApi> open(
    WidgetTester tester, {
    List<int>? selected,
    double? due,
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FakeClearingApi();
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => SettingsProvider()),
          ChangeNotifierProvider(create: (_) => AuthProvider()),
        ],
        child: MaterialApp(
          home: ClearingSettlementScreen(
            initialClearingSafeBoxId: 32,
            initialBankSafeBoxId: 37,
            initialDueAmount: due,
            initialInvoicePaymentIds: selected,
            initialTxCount: selected?.length,
            apiService: api,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return api;
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.ensureVisible(find.text('تنفيذ التسوية'));
    await tester.tap(find.text('تنفيذ التسوية'));
    await tester.pumpAndSettle();
    if (find.text('تأكيد الحفظ').evaluate().isNotEmpty) {
      await tester.tap(find.text('تأكيد الحفظ'));
      // The save button spins while the success dialog waits for «حسناً».
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      if (find.text('حسناً').evaluate().isNotEmpty) {
        await tester.tap(find.text('حسناً'));
        await tester.pump(const Duration(milliseconds: 500));
      }
    }
  }

  testWidgets('a payment chosen in the monitor is the one settled', (
    tester,
  ) async {
    final api = await open(tester, selected: [3526], due: 330);
    await settle(tester);

    expect(api.settlements, hasLength(1));
    expect(api.settlements.single.ids, [3526]);
    expect(api.settlements.single.gross, 330);
  });

  testWidgets('the cap is what was chosen, not the whole box', (tester) async {
    final api = await open(tester, selected: [3527], due: 90);
    await tester.enterText(find.byKey(const ValueKey('clearing.gross')), '500');
    await settle(tester);

    expect(api.settlements, isEmpty);
  });

  testWidgets('the chosen payments are shown before settling', (tester) async {
    await open(tester, selected: [3526], due: 330);
    expect(find.textContaining('SELL-2026-1596'), findsOneWidget);
    expect(find.textContaining('SELL-2026-1593'), findsNothing);
  });

  testWidgets(
    'opened without a choice, it settles the box oldest-first and says so',
    (tester) async {
      final api = await open(tester);
      expect(find.textContaining('أقدم الدفعات'), findsOneWidget);
      await settle(tester);

      expect(api.settlements, hasLength(1));
      expect(api.settlements.single.ids, [3520, 3526, 3527]);
    },
  );
}
