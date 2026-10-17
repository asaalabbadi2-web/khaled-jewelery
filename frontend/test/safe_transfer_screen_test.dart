import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/safe_transfer_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ADR-050 (خ١): a transfer between safes is a voucher born approved and
/// posted -- it was made on one press of «إنشاء سند التحويل». It asks first,
/// saying from where, to where and what moves.
const _safes = {
  'rows': [
    {
      'id': 1,
      'name': 'الصندوق',
      'safe_type': 'cash',
      'account_id': 70,
      'balance': {'cash': 5000.0},
    },
    {
      'id': 2,
      'name': 'بنك الرياض',
      'safe_type': 'bank',
      'account_id': 71,
      'balance': {'cash': 0.0},
    },
  ],
};

const _gold = {
  'rows': [
    {
      'id': 3,
      'name': 'الذهب المعروض',
      'safe_type': 'gold',
      'account_id': 760,
      'balance': {
        'cash': 0.0,
        'weight': {
          '18k': 0.0,
          '21k': 10.0,
          '22k': 0.0,
          '24k': 0.0,
          'total': 10.0,
        },
      },
    },
  ],
};

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  /// Opens a cash transfer from the cashbox to the bank, 1,500 typed and
  /// «إنشاء سند التحويل» pressed, then [steps]; [correction]: a karat
  /// correction of 2 g of 21k in the display safe instead.
  Future<List<Map<String, dynamic>>> run(
    WidgetTester tester,
    Future<void> Function() steps, {
    bool correction = false,
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

    final sent = <Map<String, dynamic>>[];
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
                child: SafeTransferScreen(
                  api: ApiService(),
                  initialMode: correction ? 'karat_correction' : 'cash',
                  initialFromSafeId: correction ? 3 : 1,
                  initialToSafeId: correction ? null : 2,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final (field, value, press) = correction
            ? ('الوزن (غرام)', '2', 'تصحيح العيار')
            : ('المبلغ (ر.س)', '1500', 'إنشاء سند التحويل');
        await tester.enterText(find.widgetWithText(TextField, field), value);
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(press).last);
        await tester.tap(find.text(press).last);
        await tester.pumpAndSettle();
        await steps();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return json({
            'voucher': {'id': 900, 'voucher_number': 'AV-2026-00900'},
            'transfer': {'amount_cash': 1500.0},
          }, 201);
        }
        if (path.endsWith('/safe-boxes/balances')) {
          return json(correction ? _gold : _safes);
        }
        return json({'safes': []});
      }),
    );
    return sent;
  }

  testWidgets('the transfer asks first, saying what moves', (tester) async {
    final sent = await run(tester, () async {
      expect(find.text('تنفيذ التحويل؟'), findsOneWidget);
      expect(find.text('الصندوق'), findsWidgets);
      expect(find.textContaining('1,500.00'), findsOneWidget);
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
    });

    expect(sent, isEmpty, reason: 'going back sends nothing');
  });

  testWidgets('confirmed, the transfer is sent once', (tester) async {
    final sent = await run(tester, () async {
      await tester.tap(find.byKey(const Key('confirm-action')));
      // The button spins while the success dialog waits for «حسناً».
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
    });

    expect(sent, hasLength(1));
    // خ٢: the screen says its own name, and the voucher posted, with a way
    // to open it -- in place of a dialog that listed what was just typed.
    expect(find.text('التحويل بين الخزائن'), findsOneWidget);
    expect(find.textContaining('أُنشئ سند التحويل'), findsOneWidget);
    expect(find.textContaining('AV-2026-00900'), findsOneWidget);
    expect(find.text('عرض السند'), findsOneWidget);
    expect(sent.single['amount_cash'], 1500.0);
    expect(sent.single['from_safe_box_id'], 1);
    expect(sent.single['to_safe_box_id'], 2);
  });

  testWidgets('the karat correction asks first', (tester) async {
    final sent = await run(correction: true, tester, () async {
      expect(find.text('تصحيح العيار؟'), findsOneWidget);
      expect(find.textContaining('21k → 18k'), findsOneWidget);
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
    });

    expect(sent, isEmpty);
  });
}
