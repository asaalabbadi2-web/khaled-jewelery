import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/clearing_monitor_screen.dart';
import 'package:frontend/screens/clearing_settlement_screen.dart';
import 'package:frontend/utils/currency_utils.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';
import 'support/shots.dart';

/// ADR-050 (خ١): the clearing monitor says what it knows. A box whose pending
/// payments did not load was shown «لا شيء معلّق» in green; a due amount
/// under 100 was «مبلغ بسيط معلّق», a rule of this screen alone; and «تشغيل
/// التسوية التلقائية الآن», which posts settlement vouchers, was one tap.
Map<String, dynamic> _box(int id, String name) => {
  'id': id,
  'name': name,
  'safe_type': 'clearing',
  'account_id': 700 + id,
  'is_active': true,
  'balance': {'cash': 0.0},
};

/// How many times the monitor asked for its boxes.
var loads = 0;

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  /// Opens the monitor on three Mada-like boxes: 32 owes 330, 33 owes 50,
  /// 34's pending payments fail to load. [methodsFail]: so do the methods.
  Future<List<String>> open(
    WidgetTester tester, {
    bool methodsFail = false,
    Future<void> Function()? steps,
    ThemeData? theme,
    Size size = const Size(1200, 2400),
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

    final posted = <String>[];
    loads = 0;
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
              home: const ClearingMonitorScreen(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await steps?.call();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST') {
          posted.add(path);
          return json({'message': 'تم', 'skipped': []});
        }
        if (path.endsWith('/safe-boxes')) {
          loads++;
          return json([_box(32, 'مدى'), _box(33, 'تمارا'), _box(34, 'فيزا')]);
        }
        if (path.endsWith('/payment-methods/active')) {
          return methodsFail
              ? json({'error': 'down'}, 500)
              : json([
                  {
                    'id': 10,
                    'name': 'مدى',
                    'default_safe_box_id': 32,
                    'auto_settlement_enabled': true,
                  },
                ]);
        }
        if (path.endsWith('/pending-transactions')) {
          final id = request.url.queryParameters['clearing_safe_box_id'];
          if (id == '34') return json({'error': 'down'}, 500);
          return json({
            'due_amount': id == '32' ? 330.0 : 50.0,
            'transactions': id == '32'
                ? [
                    {
                      'tx_id': 3520,
                      'invoice_payment_id': 3520,
                      'invoice_number': 'SELL-2026-1593',
                      'customer_name': 'أحمد السبيعي',
                      'amount': 3050.0,
                      'date': '2026-10-05T14:45:46',
                    },
                    {
                      'tx_id': 3526,
                      'invoice_payment_id': 3526,
                      'invoice_number': 'SELL-2026-1596',
                      'customer_name': 'نورة القحطاني',
                      'amount': 330.0,
                      'date': '2026-10-05T15:52:33',
                    },
                  ]
                : [],
          });
        }
        return json(<String, dynamic>{});
      }),
    );
    return posted;
  }

  testWidgets('a box that did not load is said so, never «nothing pending»', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('تعذّر تحميل المعلّق'), findsOneWidget);
    expect(find.byKey(const Key('clearing-boxes-failed')), findsOneWidget);
    expect(find.text('لا شيء معلّق'), findsNothing);
    expect(find.byKey(const Key('clearing-methods-failed')), findsNothing);
  });

  testWidgets('any amount owed needs settling: no rule of 100 here', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('مبلغ بسيط معلّق'), findsNothing);
    expect(find.text('يحتاج تسوية'), findsNWidgets(2));
  });

  testWidgets('methods that did not load are said so', (tester) async {
    await open(tester, methodsFail: true);

    expect(find.byKey(const Key('clearing-methods-failed')), findsOneWidget);
  });

  testWidgets('the auto settlement asks first, and going back posts nothing', (
    tester,
  ) async {
    final posted = await open(
      tester,
      steps: () async {
        await tester.tap(find.byIcon(Icons.play_circle_outline));
        await tester.pumpAndSettle();
        expect(find.text('تشغيل التسوية التلقائية الآن؟'), findsOneWidget);
        await tester.tap(find.text('تراجع'));
        await tester.pumpAndSettle();
      },
    );

    expect(posted, isEmpty);
  });

  testWidgets('confirmed, the auto settlement runs', (tester) async {
    final posted = await open(
      tester,
      steps: () async {
        await tester.tap(find.byIcon(Icons.play_circle_outline));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('confirm-action')));
        await tester.pumpAndSettle();
      },
    );

    expect(posted, hasLength(1));
    expect(posted.single, endsWith('/clearing/settlements/auto-run'));
  });

  // خ٣ (ADR-050): the monitor reads in the dark theme -- its background and
  // cards were written light (F5F5F5, white) and its text black.
  for (final (name, size) in [
    ('desktop', const Size(1440, 1100)),
    ('tablet', tabletSize),
  ]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await open(
        tester,
        theme: DarkTheme.theme,
        size: size,
        steps: () async {
          await tester.tap(find.text('مدى'));
          await tester.pumpAndSettle();
          expect(find.textContaining('SELL-2026-1596'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await shot(tester, 'clearing_monitor_dark_$name');
          expectNoTextVanishesOnDark(tester);
          expectNoLightSurfaceOnDark(tester);
        },
      );
    });
  }

  // خ٤ (ADR-050): F5 loads the monitor again; it has no search.
  testWidgets('F5 loads again', (tester) async {
    await open(
      tester,
      steps: () async {
        final before = loads;
        await tester.sendKeyEvent(LogicalKeyboardKey.f5);
        await tester.pumpAndSettle();
        expect(loads, before + 1);
      },
    );
  });

  // خ٥ (ADR-050): on a wide screen, the boxes' table beside the chosen box's
  // payments -- the cards opened one by one.
  group('the wide screen', () {
    const wide = Size(1440, 1000);

    testWidgets('a row a box; the first owing is shown with its payments', (
      tester,
    ) async {
      await open(
        tester,
        size: wide,
        steps: () async {
          for (final id in [32, 33, 34]) {
            expect(find.byKey(Key('clearing-row-$id')), findsOneWidget);
          }
          expect(find.text('مدى — الدفعات المعلّقة'), findsOneWidget);
          expect(find.text('أحمد السبيعي'), findsOneWidget);
          expect(find.text('نورة القحطاني'), findsOneWidget);

          await tester.tap(find.byKey(const Key('clearing-row-34')));
          await tester.pumpAndSettle();
          expect(
            find.text('تعذّر تحميل الدفعات المعلّقة لهذه الخزينة'),
            findsOneWidget,
          );
        },
      );
    });

    testWidgets('the search finds a payment by its customer or its invoice', (
      tester,
    ) async {
      await open(
        tester,
        size: wide,
        steps: () async {
          await tester.enterText(
            find.byKey(const Key('clearing-pay-search')),
            'نوره',
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('clearing-pay-3526')), findsOneWidget);
          expect(find.byKey(const Key('clearing-pay-3520')), findsNothing);

          await tester.enterText(
            find.byKey(const Key('clearing-pay-search')),
            '1593',
          );
          await tester.pumpAndSettle();
          expect(find.byKey(const Key('clearing-pay-3520')), findsOneWidget);
          expect(find.byKey(const Key('clearing-pay-3526')), findsNothing);
        },
      );
    });

    testWidgets('chosen payments are counted, and settled as chosen', (
      tester,
    ) async {
      await open(
        tester,
        size: wide,
        steps: () async {
          await tester.tap(find.byKey(const Key('clearing-pay-3526')));
          await tester.pumpAndSettle();
          expect(
            tester
                .widget<SarAwareText>(
                  find.byKey(const Key('clearing-selection-summary')),
                )
                .text,
            contains('330.00'),
          );
          await tester.tap(find.byKey(const Key('clearing-settle-selected')));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          final settlement = tester.widget<ClearingSettlementScreen>(
            find.byType(ClearingSettlementScreen),
          );
          expect(settlement.initialInvoicePaymentIds, [3526]);
          expect(settlement.initialClearingSafeBoxId, 32);
        },
      );
    });

    testWidgets('Ctrl+F searches the payments', (tester) async {
      await open(
        tester,
        size: wide,
        steps: () async {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
          await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
          await tester.pumpAndSettle();
          final search = tester.widget<TextField>(
            find.byKey(const Key('clearing-pay-search')),
          );
          expect(search.focusNode?.hasFocus, isTrue);
        },
      );
    });

    testWidgets('a narrow screen keeps the cards', (tester) async {
      await open(
        tester,
        size: tabletSize,
        steps: () async {
          expect(find.byKey(const Key('clearing-row-32')), findsNothing);
          expect(find.text('مدى'), findsOneWidget);
        },
      );
    });
  });
}
