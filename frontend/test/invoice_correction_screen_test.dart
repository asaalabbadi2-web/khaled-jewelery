import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/invoice_correction_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// «تصحيح فاتورة» (ADR-056, ت-3): 3314's case from the screen -- 3.3 g counted
/// as 21k, 1.5 g of it 18k. One line chosen, put right as two, in the safe the
/// gold is in now (the purchase's suggested), with a reason; the server's entry
/// shown before anything is posted; one request posts it.
const _invoice = {
  'id': 77,
  'invoice_type': 'شراء من عميل',
  'total': 1400.0,
  'items': [
    {'id': 5, 'name': 'خاتم ذهب ٢١', 'karat': 21, 'weight': 3.3, 'net': 1400.0, 'price': 1400.0},
  ],
};

const _safes = {
  'rows': [
    {'id': 46, 'name': 'عهدة عبدالله قرنان', 'safe_type': 'gold', 'stock_location': 'custody', 'account_id': 958},
    {'id': 31, 'name': 'الكسر الرئيسي', 'safe_type': 'gold', 'stock_location': 'scrap', 'account_id': 766},
    {'id': 47, 'name': 'خزنة مكتب (طرف)', 'safe_type': 'gold', 'stock_location': null, 'account_id': 900},
  ],
};

const _previewLines = [
  {'account_number': '713100014', 'account_name': 'عهدة عبدالله قرنان', 'side': 'credit', 'amount_type': 'gold', 'amount': 3.3, 'karat': 21},
  {'account_number': '713100014', 'account_name': 'عهدة عبدالله قرنان', 'side': 'debit', 'amount_type': 'gold', 'amount': 1.8, 'karat': 21},
  {'account_number': '713100014', 'account_name': 'عهدة عبدالله قرنان', 'side': 'debit', 'amount_type': 'gold', 'amount': 1.5, 'karat': 18},
];

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  Future<({List<Map<String, dynamic>> previewed, List<Map<String, dynamic>> posted, bool? popped})> run(
    WidgetTester tester,
    Future<void> Function() steps, {
    Map<String, dynamic>? previewRefusal,
  }) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final previewed = <Map<String, dynamic>>[];
    final posted = <Map<String, dynamic>>[];
    bool? popped;
    http.Response json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: settings,
            child: MaterialApp(
              theme: LightTheme.theme,
              home: Directionality(
                textDirection: TextDirection.rtl,
                child: Builder(
                  builder: (context) => Scaffold(
                    body: Center(
                      child: TextButton(
                        onPressed: () async {
                          popped = await Navigator.of(context).push<bool>(
                            MaterialPageRoute(
                              builder: (_) => InvoiceCorrectionScreen(api: ApiService(), invoiceId: 77),
                            ),
                          );
                        },
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await steps();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/invoices/77/corrections/preview')) {
          previewed.add(jsonDecode(request.body) as Map<String, dynamic>);
          if (previewRefusal != null) return json(previewRefusal, 400);
          return json({'preview': true, 'lines': _previewLines, 'cash_delta': 0.0});
        }
        if (request.method == 'POST' && path.endsWith('/invoices/77/corrections')) {
          posted.add(jsonDecode(request.body) as Map<String, dynamic>);
          return json({'id': 1, 'entry_number': 'COR-2026-00056'}, 201);
        }
        if (path.endsWith('/invoices/77/corrections')) {
          return json({'corrections': [], 'suggested_safe_box_id': 46});
        }
        if (path.endsWith('/invoices/77')) return json(_invoice);
        if (path.endsWith('/safe-boxes/balances')) return json(_safes);
        return json(<String, dynamic>{});
      }),
    );
    return (previewed: previewed, posted: posted, popped: popped);
  }

  Future<void> fill(WidgetTester tester, {bool reason = true}) async {
    await tester.tap(find.text('خاتم ذهب ٢١'));
    await tester.pumpAndSettle();
    final weights = find.widgetWithText(TextField, 'الوزن (جم)');
    final prices = find.widgetWithText(TextField, 'السعر');
    await tester.enterText(weights.at(0), '1.8');
    await tester.enterText(prices.at(0), '800');
    await tester.tap(find.textContaining('إضافة سطر'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'الوزن (جم)').at(1), '1.5');
    await tester.enterText(find.widgetWithText(TextField, 'السعر').at(1), '600');
    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, 'العيار').at(1));
    await tester.pumpAndSettle();
    await tester.tap(find.text('18').last);
    await tester.pumpAndSettle();
    if (reason) {
      await tester.enterText(find.widgetWithText(TextField, 'سبب التصحيح'), 'تصحيح عيار');
    }
    await tester.pumpAndSettle();
  }

  testWidgets('3314 from the screen: two right lines in the suggested custody, the server\'s entry, one post',
      (tester) async {
    final sent = await run(tester, () async {
      await fill(tester);
      await tester.tap(find.text('معاينة القيد ثم التصحيح'));
      await tester.pumpAndSettle();
      expect(find.text('تأكيد التصحيح'), findsWidgets);
      expect(find.textContaining('713100014'), findsWidgets, reason: 'the server\'s entry, not a summary');
      await tester.tap(find.widgetWithText(FilledButton, 'تأكيد التصحيح'));
      await tester.pumpAndSettle();
    });
    const body = {
      'line_id': 5,
      'safe_box_id': 46,
      'reason': 'تصحيح عيار',
      'lines': [
        {'karat': 21, 'weight': 1.8, 'price': 800.0},
        {'karat': 18, 'weight': 1.5, 'price': 600.0},
      ],
    };
    expect(sent.previewed, [body]);
    expect(sent.posted, [body]);
    expect(sent.popped, isTrue);
  });

  testWidgets('a party\'s gold safe is no place to correct gold in', (tester) async {
    await run(tester, () async {
      await fill(tester);
      await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, 'الخزينة التي فيها ذهب السطر الآن'));
      await tester.pumpAndSettle();
      expect(find.text('الكسر الرئيسي'), findsWidgets);
      expect(find.text('خزنة مكتب (طرف)'), findsNothing);
    });
  });

  testWidgets('no reason: said, nothing sent', (tester) async {
    final sent = await run(tester, () async {
      await fill(tester, reason: false);
      await tester.tap(find.text('معاينة القيد ثم التصحيح'));
      await tester.pumpAndSettle();
      expect(find.text('سبب التصحيح مطلوب'), findsOneWidget);
    });
    expect(sent.previewed, isEmpty);
    expect(sent.posted, isEmpty);
  });

  testWidgets('the server refuses the preview: said in its words, nothing posted', (tester) async {
    final sent = await run(
      tester,
      () async {
        await fill(tester);
        await tester.tap(find.text('معاينة القيد ثم التصحيح'));
        await tester.pumpAndSettle();
        expect(find.textContaining('لا تحمل 3.300 غ'), findsOneWidget);
      },
      previewRefusal: {'error': 'insufficient_balance', 'message': '«العهدة» لا تحمل 3.300 غ عيار 21: أين ذهب السطر الآن؟'},
    );
    expect(sent.previewed, hasLength(1));
    expect(sent.posted, isEmpty);
  });
}
