import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/original_invoice_selector.dart';

import 'support/fake_sales_api.dart';

/// The return audit, M3 (11 Nov 2026): the picker fetched every invoice at
/// each opening, named each by its row id and searched it so. Now it asks the
/// server as it is typed, a page at a time, and says each by its number and
/// what remains of it; one returned whole is not offered.
class _Api extends FakeSalesApi {
  final asked = <Map<String, Object?>>[];

  @override
  Future<Map<String, dynamic>> getReturnableInvoices({
    String? invoiceType,
    int? customerId,
    int? supplierId,
    String? search,
    int page = 1,
    int perPage = 20,
  }) async {
    asked.add({'search': search, 'page': page});
    Map<String, dynamic> inv(int id, {bool whole = false}) => {
          'id': id, 'invoice_number': 'SELL-2026-${1900 + id}', 'customer_name': 'عميل $id',
          'date': '2026-11-0${id % 9 + 1}T10:00:00', 'total': 10000.0 + id,
          'remaining_grams': whole ? 0.0 : 20.0, 'remaining_amount': whole ? 0.0 : 9000.0,
          'can_return': !whole,
        };
    if ((search ?? '').isNotEmpty) {
      return {'invoices': [inv(82)], 'total_count': 1, 'has_more': false};
    }
    return page == 1
        ? {'invoices': [inv(1), inv(2, whole: true)], 'total_count': 3, 'has_more': true}
        : {'invoices': [inv(3)], 'total_count': 3, 'has_more': false};
  }
}

Future<_Api> _open(WidgetTester tester) async {
  final api = _Api();
  await tester.pumpWidget(MaterialApp(
    theme: LightTheme.theme,
    home: Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: OriginalInvoiceSelector(api: api, invoiceType: 'بيع', onInvoiceSelected: (_) {}),
      ),
    ),
  ));
  await tester.tap(find.text('اختر الفاتورة الأصلية'));
  await tester.pumpAndSettle();
  return api;
}

void main() {
  testWidgets('each is said by its number and what remains; one returned whole is not offered', (tester) async {
    await _open(tester);
    expect(find.textContaining('SELL-2026-1901 · عميل 1'), findsOneWidget);
    expect(find.textContaining('يبقى 20.000 جم بـ9,000.00'), findsOneWidget);
    final whole = find.byKey(const ValueKey('original-invoice-2'));
    expect(find.descendant(of: whole, matching: find.textContaining('رُدّت كلها')), findsOneWidget);
    expect(tester.widget<ListTile>(find.descendant(of: whole, matching: find.byType(ListTile))).enabled, isFalse);
  });

  testWidgets('what is typed is asked of the server', (tester) async {
    final api = await _open(tester);
    await tester.enterText(find.byKey(const Key('original-invoice-search')), '1982');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(api.asked.last['search'], '1982');
    expect(find.textContaining('SELL-2026-1982'), findsOneWidget);
    expect(find.textContaining('SELL-2026-1901'), findsNothing);
  });

  testWidgets('a page at a time, the next on «المزيد»', (tester) async {
    final api = await _open(tester);
    expect(find.textContaining('SELL-2026-1903'), findsNothing);
    await tester.tap(find.byKey(const Key('original-invoice-more')));
    await tester.pumpAndSettle();
    expect(api.asked.last['page'], 2);
    expect(find.textContaining('SELL-2026-1903'), findsOneWidget);
    expect(find.textContaining('SELL-2026-1901'), findsOneWidget, reason: 'added to, not replaced');
  });
}
