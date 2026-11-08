// ADR-087 R2: receiving a supplier's gold before his invoice. A line is a
// category of its karat with the supplier's weight and the weight received,
// their difference said beside it. What is sent: his paper's number, the
// key of the attempt, the lines. Above the tolerance the server refuses; the
// screen asks the reason and sends it again with the same key.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/receiving_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api extends ApiService {
  final sent = <Map<String, dynamic>>[];
  bool refuseFirst = false;

  @override
  Future<List<dynamic>> getSuppliers() async => [
    {'id': 14, 'name': 'مفيد الحبيشي'},
  ];

  @override
  Future<List<dynamic>> getCategories({bool includeInactive = false}) async => [
    {'id': 28, 'name': 'بنجرة ذهب 21', 'karat': '21', 'is_active': true},
    {'id': 30, 'name': 'طقم ذهب 18', 'karat': '18', 'is_active': true},
    {'id': 42, 'name': 'كسر 21', 'karat': '21', 'is_active': true, 'is_scrap': true},
  ];

  @override
  Future<Map<String, dynamic>> receivePurchase(Map<String, dynamic> body) async {
    sent.add(body);
    if (refuseFirst && sent.length == 1) {
      throw const ApiException(
        statusCode: 400,
        code: 'receipt_difference_over_tolerance',
        message: 'فرق الوزن فوق الحدّ (0.10 جم): السطر 1: -0.40 جم',
      );
    }
    return {
      'invoice': {'id': 900, 'invoice_number': 'PUR-2027-00001'},
    };
  }
}

Future<void> _open(WidgetTester tester, _Api api) async {
  SharedPreferences.setMockInitialValues({'jwt_token': 't'});
  tester.view.physicalSize = const Size(1400, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ChangeNotifierProvider(
      create: (_) => SettingsProvider(),
      child: MaterialApp(
        theme: LightTheme.theme,
        home: ReceivingScreen(api: api),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _receiveOneLine(WidgetTester tester) async {
  await tester.tap(find.text('اضغط للبحث والاختيار'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('مفيد الحبيشي').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('receiving-paper-number')), 'P-17');
  await tester.tap(find.byKey(const Key('receiving-category')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('بنجرة ذهب 21').last);
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('receiving-supplier-weight')), '216.4');
  await tester.enterText(find.byKey(const Key('receiving-weight')), '216.0');
  await tester.tap(find.byKey(const Key('receiving-add')));
  await tester.pumpAndSettle();
}

Future<void> _saveAndConfirm(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('receiving-save')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('confirm-action')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a line says both weights and their difference; saved, it sends them', (tester) async {
    final api = _Api();
    await _open(tester, api);
    expect(find.text('كسر 21'), findsNothing, reason: 'no scrap category for new gold');
    await _receiveOneLine(tester);
    expect(find.textContaining('-0.40'), findsOneWidget);
    await _saveAndConfirm(tester);
    final body = api.sent.single;
    expect(body['supplier_id'], 14);
    expect(body['supplier_invoice_number'], 'P-17');
    expect(body['request_key'], isNotEmpty);
    expect(body['lines'], [
      {'category_id': 28, 'karat': 21, 'weight': 216.0, 'supplier_weight': 216.4},
    ]);
    expect(find.textContaining('PUR-2027-00001'), findsOneWidget);
  });

  testWidgets('above the tolerance it asks the reason and sends again with the same key', (tester) async {
    final api = _Api()..refuseFirst = true;
    await _open(tester, api);
    await _receiveOneLine(tester);
    await _saveAndConfirm(tester);
    expect(find.text('فرق الوزن فوق الحدّ'), findsOneWidget);
    await tester.enterText(
      find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)),
      'ميزان المورد غير معاير',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(2));
    expect(api.sent[1]['request_key'], api.sent[0]['request_key'], reason: 'one document');
    expect(api.sent[1]['difference_approval'], {'reason': 'ميزان المورد غير معاير'});
  });

  testWidgets('it lays out on a phone', (tester) async {
    tester.view.physicalSize = const Size(390, 1800);
    await _open(tester, _Api());
    expect(tester.takeException(), isNull);
  });
}
