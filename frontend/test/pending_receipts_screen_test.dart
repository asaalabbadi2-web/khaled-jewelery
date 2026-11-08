// ADR-087 R2: «استلامات بلا فاتورة» -- each receipt waiting for its invoice,
// its supplier, his paper's number, its weight by karat; «استكمال الفاتورة»
// opens its completion, and a completed one leaves the list.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/pending_receipts_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiService {
  var waiting = [
    {
      'id': 88,
      'invoice_number': 'PUR-2027-00001',
      'date': '2027-01-04T10:00:00',
      'supplier_name': 'مفيد الحبيشي',
      'supplier_invoice_number': 'P-17',
      'weight_by_karat': {'21': 216.3},
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> pendingReceipts() async => waiting;
}

void main() {
  testWidgets('a receipt says its supplier, paper and weight; completed, it leaves', (tester) async {
    SharedPreferences.setMockInitialValues({'jwt_token': 't'});
    final api = _Api();
    final opened = <int>[];
    await tester.pumpWidget(MaterialApp(
      theme: LightTheme.theme,
      home: PendingReceiptsScreen(
        api: api,
        onComplete: (_, r) async {
          opened.add(r['id'] as int);
          api.waiting = [];
          return true;
        },
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('مفيد الحبيشي'), findsOneWidget);
    expect(find.textContaining('P-17'), findsOneWidget);
    expect(find.textContaining('216.30'), findsOneWidget);
    await tester.tap(find.byKey(const Key('complete-88')));
    await tester.pumpAndSettle();
    expect(opened, [88]);
    expect(find.text('لا استلام ينتظر فاتورته'), findsOneWidget);
  });
}
