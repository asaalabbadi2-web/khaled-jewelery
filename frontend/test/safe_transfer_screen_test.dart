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

import 'support/dark_text.dart';
import 'support/payload_witness.dart';

/// The transfer between safes (ADR-050).
///
/// خ١: a transfer and a karat correction are vouchers born approved and
/// posted; each asks first, saying what moves. خ٢: success says the voucher
/// with «عرض السند». The redesign (the owner, 17 Oct 2026: «بحاجة إعادة
/// تصميم لتجربة المستخدم والواجهة»): one page -- the operation in sight, from
/// → to side by side, a row a karat the source holds with «الكل» and what is
/// left, and a bar under the page saying what moves and what is missing. What
/// it sends is the screen's before it (test/payloads/safe_transfer_*.json,
/// written from it).
Map<String, dynamic> _gold(int id, String name, Map<String, double> w) => {
  'id': id,
  'name': name,
  'safe_type': 'gold',
  'account_id': 700 + id,
  'balance': {
    'cash': 0.0,
    'weight': {...w, 'total': 0.0},
  },
};

final _goldSafes = [
  _gold(30, 'خزينة الذهب المعروض', {
    '18k': 100.0,
    '21k': 200.0,
    '22k': 0.0,
    '24k': -176.0,
  }),
  _gold(31, 'صندوق الكسر', {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0}),
];

final _cashSafes = [
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
];

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  /// Opens the screen in [mode] (gold 30 → 31, cash 1 → 2, a correction in
  /// 30), runs [steps], and returns what was posted: {path, body}.
  Future<List<Map<String, dynamic>>> run(
    WidgetTester tester,
    String mode,
    Future<void> Function() steps, {
    ThemeData? theme,
    Size size = const Size(1200, 2000),
  }) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = size;
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
              theme: theme ?? LightTheme.theme,
              home: Directionality(
                textDirection: TextDirection.rtl,
                child: SafeTransferScreen(
                  api: ApiService(),
                  initialMode: mode,
                  initialFromSafeId: mode == 'cash' ? 1 : 30,
                  initialToSafeId: switch (mode) {
                    'cash' => 2,
                    'gold' => 31,
                    _ => null,
                  },
                  initialNotes: 'ملاحظة',
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await steps();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          sent.add({
            'path': path.replaceFirst(RegExp(r'^.*/api'), ''),
            'body': jsonDecode(request.body),
          });
          return json({
            'voucher': {'id': 900, 'voucher_number': 'AV-2026-00900'},
          }, 201);
        }
        if (path.endsWith('/safe-boxes/balances')) {
          return json({'rows': mode == 'cash' ? _cashSafes : _goldSafes});
        }
        return json({
          'safes': [
            {
              'safe_box_id': 30,
              'stones_balance': 12.5,
              'by_karat': {'21': 10.0, '18': 2.5},
            },
          ],
        });
      }),
    );
    return sent;
  }

  Future<void> type(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.byKey(Key(key)), text);
    await tester.pumpAndSettle();
  }

  /// The bar's button, then the confirmation's.
  Future<void> submitAndConfirm(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('transfer-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-action')));
    await tester.pumpAndSettle();
  }

  group('what is sent is what the screen sent before its redesign', () {
    testWidgets('gold: two karats and stones', (tester) async {
      final sent = await run(tester, 'gold', () async {
        await type(tester, 'transfer-weight-21', '5.7');
        await type(tester, 'transfer-weight-18', '2');
        await tester.tap(find.byKey(const Key('transfer-show-stones')));
        await tester.pumpAndSettle();
        await type(tester, 'transfer-stones-21', '1');
        await submitAndConfirm(tester);
      });
      expect(sent, hasLength(1));
      expectPayload('safe_transfer_gold', sent.single);
    });

    testWidgets('cash', (tester) async {
      final sent = await run(tester, 'cash', () async {
        await type(tester, 'transfer-amount', '1500');
        await submitAndConfirm(tester);
      });
      expect(sent, hasLength(1));
      expectPayload('safe_transfer_cash', sent.single);
    });

    testWidgets('karat correction', (tester) async {
      final sent = await run(tester, 'karat_correction', () async {
        await type(tester, 'correction-weight', '2');
        await submitAndConfirm(tester);
      });
      expect(sent, hasLength(1));
      expectPayload('safe_karat_correction', sent.single);
    });
  });

  testWidgets('it asks first, saying what moves; going back sends nothing', (
    tester,
  ) async {
    final sent = await run(tester, 'cash', () async {
      await type(tester, 'transfer-amount', '1500');
      await tester.tap(find.byKey(const Key('transfer-submit')));
      await tester.pumpAndSettle();
      expect(find.text('تنفيذ التحويل؟'), findsOneWidget);
      expect(find.textContaining('1,500.00'), findsWidgets);
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
    });
    expect(sent, isEmpty);
  });

  testWidgets('the karat correction asks first', (tester) async {
    final sent = await run(tester, 'karat_correction', () async {
      await type(tester, 'correction-weight', '2');
      await tester.tap(find.byKey(const Key('transfer-submit')));
      await tester.pumpAndSettle();
      expect(find.text('تصحيح العيار؟'), findsOneWidget);
      expect(find.textContaining('21k → 18k'), findsWidgets);
      await tester.tap(find.text('تراجع'));
      await tester.pumpAndSettle();
    });
    expect(sent, isEmpty);
  });

  testWidgets('posted, it says the voucher with «عرض السند»', (tester) async {
    await run(tester, 'cash', () async {
      await type(tester, 'transfer-amount', '1500');
      await submitAndConfirm(tester);
    });
    expect(find.text('التحويل بين الخزائن'), findsOneWidget);
    expect(find.textContaining('أُنشئ سند التحويل'), findsOneWidget);
    expect(find.textContaining('AV-2026-00900'), findsOneWidget);
    expect(find.text('عرض السند'), findsOneWidget);
  });

  group('the page', () {
    testWidgets('a row a karat the source holds; another on asking', (
      tester,
    ) async {
      await run(tester, 'gold', () async {
        // 21 and 18 held; 22 empty and 24 below zero are not rows.
        for (final k in [21, 18]) {
          expect(find.byKey(Key('transfer-weight-$k')), findsOneWidget);
        }
        for (final k in [22, 24]) {
          expect(find.byKey(Key('transfer-weight-$k')), findsNothing);
        }
        // The negative balance is said, apart from 18k's tone.
        expect(find.byKey(const Key('transfer-negative-24')), findsOneWidget);

        await tester.tap(find.byKey(const Key('transfer-other-karat')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('22k').last);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('transfer-weight-22')), findsOneWidget);
      });
    });

    testWidgets('«الكل» moves all of a karat; what is left is said', (
      tester,
    ) async {
      await run(tester, 'gold', () async {
        await tester.tap(find.byKey(const Key('transfer-all-21')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('transfer-weight-21')))
              .controller!
              .text,
          '200.000',
        );
        await type(tester, 'transfer-weight-18', '30');
        expect(
          tester.widget<Text>(find.byKey(const Key('transfer-left-18'))).data,
          contains('70.000'),
        );
      });
    });

    testWidgets('the button waits, and says what is missing', (tester) async {
      await run(tester, 'gold', () async {
        FilledButton button() => tester.widget<FilledButton>(
          find.byKey(const Key('transfer-submit')),
        );
        String blocker() => tester
            .widget<Text>(find.byKey(const Key('transfer-blocker')))
            .data!;

        expect(button().onPressed, isNull);
        expect(blocker(), 'أدخل وزنًا في عيار واحد على الأقل');

        await type(tester, 'transfer-weight-21', '250');
        expect(button().onPressed, isNull);
        expect(blocker(), 'وزن أكبر من المتاح');

        await type(tester, 'transfer-weight-21', '5');
        expect(button().onPressed, isNotNull);
        expect(find.byKey(const Key('transfer-blocker')), findsNothing);
        expect(
          tester.widget<Text>(find.byKey(const Key('transfer-summary'))).data,
          contains('21k'),
        );
      });
    });

    testWidgets('the swap turns source and destination', (tester) async {
      await run(tester, 'gold', () async {
        await tester.tap(find.byKey(const Key('transfer-swap')));
        await tester.pumpAndSettle();
        // صندوق الكسر is the source now: it holds nothing to move.
        expect(find.text('لا رصيد ذهب في خزينة المصدر.'), findsOneWidget);
      });
    });

    testWidgets('Ctrl+S asks, as the button does', (tester) async {
      await run(tester, 'cash', () async {
        await type(tester, 'transfer-amount', '100');
        // Out of the field, as the employee leaves it with Tab.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pumpAndSettle();
        expect(find.text('تنفيذ التحويل؟'), findsOneWidget);
      });
    });

    for (final (name, size) in [
      ('a tablet', const Size(820, 1180)),
      ('a phone', const Size(390, 844)),
    ]) {
      testWidgets('it lays out on $name, in the dark theme too', (
        tester,
      ) async {
        await run(
          tester,
          'gold',
          () async {
            await type(tester, 'transfer-weight-21', '5');
            expect(tester.takeException(), isNull);
            expectNoTextVanishesOnDark(tester);
            expectNoLightSurfaceOnDark(tester);
          },
          theme: DarkTheme.theme,
          size: size,
        );
      });
    }
  });
}
