// The attribution sheet (2 Oct 2026): gold and cash, one way of choosing.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/invoice_attribution_sheet.dart';

Widget _host(InvoiceAttributionSheet sheet) => MaterialApp(
      home: Directionality(textDirection: TextDirection.rtl, child: Scaffold(body: sheet)),
    );

InvoiceAttributionSheet _sheet({
  double unattributed = 1150,
  List<AttributionCandidate>? candidates,
  List<AttributionExisting> existing = const [],
  Future<void> Function(int, double)? onAttribute,
}) =>
    InvoiceAttributionSheet(
      title: 'نسب نقد السند إلى فاتورة',
      unit: 'ر.س',
      unattributed: unattributed,
      emptyText: 'لا توجد فواتير',
      existing: existing,
      candidates: candidates ??
          [
            AttributionCandidate(invoiceId: 10, label: 'شراء #150', open: 400, date: DateTime(2026, 8, 1)),
            AttributionCandidate(invoiceId: 3133, label: 'شراء #187', open: 1150, date: DateTime(2026, 9, 27)),
          ],
      onAttribute: onAttribute ?? (_, _) async {},
      onRemove: (_) async {},
    );

void main() {
  test('the weight sent is in the voucher\'s karat, not the main karat', () {
    expect(karatWeightFromMain(20.743, 21, 18), 24.2);
    expect(karatWeightFromMain(10, 21, 21), 10.0);
  });

  testWidgets('an invoice that matches exactly comes first, marked, and nothing is chosen', (tester) async {
    await tester.pumpWidget(_host(_sheet()));
    final first = tester.getTopLeft(find.byKey(const ValueKey('candidate-3133'))).dy;
    final second = tester.getTopLeft(find.byKey(const ValueKey('candidate-10'))).dy;
    expect(first < second, isTrue);
    expect(find.byKey(const ValueKey('exact-3133')), findsOneWidget);
    expect(find.byKey(const ValueKey('exact-10')), findsNothing);
    expect(find.byKey(const ValueKey('attribution-amount')), findsNothing);
  });

  testWidgets('the search narrows the invoices by number', (tester) async {
    await tester.pumpWidget(_host(_sheet()));
    await tester.enterText(find.byKey(const ValueKey('attribution-search')), '187');
    await tester.pump();
    expect(find.byKey(const ValueKey('candidate-3133')), findsOneWidget);
    expect(find.byKey(const ValueKey('candidate-10')), findsNothing);
  });

  testWidgets('the amount is capped by both sides and refused above it', (tester) async {
    final calls = <List<num>>[];
    await tester.pumpWidget(_host(_sheet(onAttribute: (id, a) async => calls.add([id, a]))));
    await tester.tap(find.byKey(const ValueKey('candidate-10')));
    await tester.pump();
    expect(find.text('400.00'), findsOneWidget); // min(1150 unattributed, 400 open)
    await tester.enterText(find.byKey(const ValueKey('attribution-amount')), '500');
    await tester.tap(find.byKey(const ValueKey('attribution-confirm')));
    await tester.pump();
    expect(find.textContaining('الحد الأقصى 400.00'), findsWidgets);
    expect(calls, isEmpty);
  });

  testWidgets('confirming writes the chosen invoice and amount, after a summary', (tester) async {
    final calls = <List<num>>[];
    await tester.pumpWidget(_host(_sheet(onAttribute: (id, a) async => calls.add([id, a]))));
    await tester.tap(find.byKey(const ValueKey('candidate-3133')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('attribution-confirm')));
    await tester.pumpAndSettle();
    expect(find.textContaining('شراء #187'), findsWidgets); // the summary names it
    expect(calls, isEmpty);
    await tester.tap(find.widgetWithText(FilledButton, 'انسب').last);
    await tester.pumpAndSettle();
    expect(calls, [
      [3133, 1150.0]
    ]);
  });

  testWidgets('a voucher\'s own payment shows a lock, not a delete', (tester) async {
    await tester.pumpWidget(_host(_sheet(existing: const [
      AttributionExisting(id: 1, label: 'فاتورة #3133', amount: 1150, removable: false),
      AttributionExisting(id: 2, label: 'فاتورة #10', amount: 100, removable: true),
    ])));
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);
  });
}
