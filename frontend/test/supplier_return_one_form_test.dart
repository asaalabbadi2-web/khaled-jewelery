import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/add_return_invoice_screen.dart';
import 'package:frontend/screens/purchase_invoice_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_purchase_api.dart';

/// One form for a supplier's return, the purchase screen's (25 Oct 2026).
/// The general return form -- made for a customer, whose refund is cash --
/// refunded the gold's value too: a receipt of cash never received, and the
/// wages left unreversed. The side menu and the invoices list's «return» on a
/// purchase opened it.
/// The purchase being returned: 72.22 g at 12.75 a gram -- 920.81 in wages.
/// An invoice item's `wage` is the wage a gram, as the server keeps it.
class _OriginalApi extends FakePurchaseApi {
  /// 41 of 224 supplier purchases on the 22 Nov copy carry no branch.
  int? branchId = 1;

  @override
  Future<Map<String, dynamic>> getInvoiceById(int invoiceId) async => {
        'id': invoiceId, 'supplier_id': 1, 'branch_id': branchId, 'invoice_type': 'شراء', 'vat_applied': false,
        'total_tax': 0,
        'items': [
          {'id': 4922, 'name': 'بناجر', 'karat': 21, 'weight': 72.22, 'wage': 12.75, 'quantity': 1},
        ],
      };
}

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  testWidgets('the general form asked for a supplier\'s return is the purchase screen, its original chosen',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AddReturnInvoiceScreen(
            api: FakePurchaseApi(),
            returnType: 'مرتجع شراء (مورد)',
            prefilledOriginalInvoice: const {'id': 3470, 'supplier_id': 14},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final screen = tester.widget<PurchaseInvoiceScreen>(find.byType(PurchaseInvoiceScreen));
    expect(screen.supplierReturnMode, isTrue);
    expect((screen.originalInvoiceId, screen.supplierId), (3470, 14));
  });

  test('no entrance opens the general form for a supplier\'s return', () {
    final offenders = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      for (final m in RegExp(r'AddReturnInvoiceScreen\(').allMatches(text)) {
        final call = text.substring(m.start, (m.start + 260).clamp(0, text.length));
        if (call.contains("'مرتجع شراء (مورد)'")) offenders.add(file.path);
      }
    }
    expect(offenders, isEmpty);
  });

  testWidgets('a return of a purchase takes its wage a gram, not the wage a gram as the line\'s wage',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PurchaseInvoiceScreen(apiService: _OriginalApi(), supplierReturnMode: true, originalInvoiceId: 3470),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('920.81', findRichText: true), findsWidgets, reason: '72.22 g × 12.75');
  });

  // The owner, 23 Nov 2026 (the cycle rehearsal): «تحميل فاتورة المورد في
  // المرتجع فشل» -- an original with no branch never loaded; the server never asked for one.
  testWidgets('an original with no branch loads, and its lines are offered', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PurchaseInvoiceScreen(apiService: _OriginalApi()..branchId = null, supplierReturnMode: true,
              originalInvoiceId: 3470),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('تعذر تحميل'), findsNothing);
    expect(find.textContaining('920.81', findRichText: true), findsWidgets, reason: 'its line loaded');
  });

  // «القطعة ترجع كاملة» -- a coded line goes back to its supplier by its
  // pieces in the stock, each whole, and its rest (the owner, 18 Nov 2026) --
  // each piece scanned onto the return (the owner, 23 Nov 2026: «يفضل في المرتجع المسح»).
  testWidgets('a coded line goes back by its pieces scanned, each whole, and its rest', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1440, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _OriginalApi()
      ..codedLines = {
        '4922': {
          'rest': 2.22,
          'pieces': [
            {'id': 40, 'item_code': 'KJ-000004', 'weight': 44.0},
            {'id': 41, 'item_code': 'KJ-000005', 'weight': 26.0},
          ],
        },
      }
      ..activeTags = {'4B4A00010000000000000005': 'KJ-000005'};
    await tester.pumpWidget(MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => SettingsProvider()),
      ],
      child: MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: PurchaseInvoiceScreen(apiService: api, supplierReturnMode: true, originalInvoiceId: 3470),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('تُرجَع كاملة'), findsNothing, reason: 'no piece on the return until scanned');
    String said() => tester.widget<Text>(find.byKey(const Key('return-piece-scan-state'))).data!;
    expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('return-piece-scan')),
        matching: find.byType(EditableText))).focusNode.hasFocus, isTrue, reason: 'the reader types here at once');
    await tester.enterText(find.byKey(const Key('return-piece-scan')), 'KJ-000004');   // its printed number
    await tester.pumpAndSettle();
    expect(said(), contains('أُضيفت KJ-000004'));
    await tester.enterText(find.byKey(const Key('return-piece-scan')), 'KJ-000009');
    await tester.pumpAndSettle();
    expect(said(), 'القطعة KJ-000009 ليست من قطع هذه الفاتورة الباقية في المخزون');
    await tester.enterText(find.byKey(const Key('return-piece-scan')), 'KJ-000004');
    await tester.pumpAndSettle();
    expect(said(), 'القطعة KJ-000004 مضافة في المرتجع', reason: 'once');
    await tester.enterText(find.byKey(const Key('return-piece-scan')), '4B4A00010000000000000005');  // its tag, no Enter
    await tester.pumpAndSettle();
    expect(said(), contains('أُضيفت KJ-000005'));
    expect(tester.widget<EditableText>(find.descendant(of: find.byKey(const Key('return-piece-scan')),
        matching: find.byType(EditableText))).focusNode.hasFocus, isTrue, reason: 'the next piece read where the last was');
    expect(find.text('القطعة KJ-000004 تُرجَع كاملة'), findsOneWidget);
    expect(find.text('القطعة KJ-000005 تُرجَع كاملة'), findsOneWidget);
    expect(find.byTooltip('تفاصيل'), findsOneWidget, reason: 'only the rest is edited; a piece is removed or kept');
    expect(tester.widget(find.byKey(const ValueKey('weight-1'))), isA<Text>(), reason: 'a piece\'s weight is read, not typed');
    expect(tester.widget(find.byKey(const ValueKey('weight-0'))), isNot(isA<Text>()), reason: 'the rest is typed');
    await tester.tap(find.text('حفظ المرتجع', findRichText: true).last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('حفظ الفاتورة').last);   // the review's
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final lines = [for (final i in (api.added.single['items'] as List)) (i['item_id'], i['weight'])];
    expect(lines, [(null, 2.22), (40, 44.0), (41, 26.0)]);
  });
}
