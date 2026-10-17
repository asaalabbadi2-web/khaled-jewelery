import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/melting_renewal_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';
import 'support/payload_witness.dart';
import 'support/shots.dart';

/// ADR-050: a melting of several karats is one request -- one voucher, its
/// damage wage posted once. The screen sent a request per line, the wage
/// with each: three lines posted it three times.
const _safes = {
  'rows': [
    {
      'id': 1,
      'name': 'الذهب المعروض',
      'safe_type': 'gold',
      'account_id': 760,
      'balance': {
        'cash': 0.0,
        'weight': {
          '18k': 10.0,
          '21k': 10.0,
          '22k': 0.0,
          '24k': 0.0,
          'total': 0.0,
        },
      },
    },
    {
      'id': 2,
      'name': 'صندوق الكسر',
      'safe_type': 'gold',
      'account_id': 761,
      'balance': {
        'cash': 0.0,
        'weight': {
          '18k': 0.0,
          '21k': 0.0,
          '22k': 0.0,
          '24k': 0.0,
          'total': 0.0,
        },
      },
    },
  ],
};

const _accounts = [
  {
    'id': 51,
    'account_number': '5410',
    'name': 'مصروف مصنعية تالفة',
    'type': 'expense',
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

  /// Opens the screen on [_safes], runs [steps] as the employee would, and
  /// returns what reached `/melting-renewal`.
  Future<List<Map<String, dynamic>>> run(
    WidgetTester tester,
    Future<void> Function() steps, {
    String? warning,
    ThemeData? theme,
    Size size = const Size(1200, 2400),
    bool overAPage = false,
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
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          ChangeNotifierProvider.value(
            value: settings,
            child: MaterialApp(
              theme: theme ?? LightTheme.theme,
              home: Directionality(
                textDirection: TextDirection.rtl,
                child: overAPage
                    ? Builder(
                        builder: (context) => Scaffold(
                          body: Center(
                            child: TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) =>
                                      MeltingRenewalScreen(api: ApiService()),
                                ),
                              ),
                              child: const Text('open'),
                            ),
                          ),
                        ),
                      )
                    : MeltingRenewalScreen(api: ApiService()),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (overAPage) {
          await tester.tap(find.text('open'));
          await tester.pumpAndSettle();
        }
        await steps();
      },
      () => MockClient((request) async {
        final path = request.url.path;
        if (request.method == 'POST' && path.endsWith('/melting-renewal')) {
          sent.add(jsonDecode(request.body) as Map<String, dynamic>);
          return http.Response(
            jsonEncode({
              'voucher': {'id': 42, 'voucher_number': 'ADJ-2026-00042'},
              'warning': ?warning,
            }),
            201,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        final body = path.endsWith('/safe-boxes/balances')
            ? _safes
            : path.endsWith('/accounts')
            ? _accounts
            : path.endsWith('/stones-balance')
            ? {'safes': []}
            : <String, dynamic>{};
        return http.Response(
          jsonEncode(body),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
    return sent;
  }

  Future<void> typeWage(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextFormField, 'قيمة أجرة الصنعة المهدرة بالتكسير'),
      '100',
    );
    await tester.pumpAndSettle();
  }

  Future<void> execute(WidgetTester tester) async {
    await tester.ensureVisible(find.text('تنفيذ التكسير'));
    await tester.tap(find.text('تنفيذ التكسير'));
    await tester.pumpAndSettle();
  }

  testWidgets('two karats and a wage are sent as one operation', (
    tester,
  ) async {
    final sent = await run(tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      await tester.tap(find.text('إضافة سطر عيار'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('21k').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('18k').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').last,
        '1.5',
      );
      await typeWage(tester);
      await tester.tap(find.text('حساب مصروف المصنعية'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('مصروف مصنعية تالفة').last);
      await tester.pumpAndSettle();
      await execute(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'تأكيد التكسير'));
      await tester.pumpAndSettle();
    });

    expect(sent, hasLength(1), reason: 'one operation, one request');
    expectPayload('melting_two_karats', sent.single);
    expect(find.textContaining('ADJ-2026-00042'), findsOneWidget);
    expect(find.text('عرض السند'), findsOneWidget);
  });

  testWidgets('a wage without its account is not sent', (tester) async {
    // The server drops a wage that names no account, unsaid, while the
    // confirmation showed it.
    final sent = await run(tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      await typeWage(tester);
      await execute(tester);
    });

    expect(sent, isEmpty);
    expect(find.text('اختر حساب مصروف المصنعية'), findsOneWidget);
    expect(find.text('تأكيد التكسير'), findsNothing);
  });

  testWidgets('a karat\'s lines are weighed together', (tester) async {
    // Two lines of 21k, 6 g each, within the 10 g held; not together.
    final sent = await run(tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '6',
      );
      await tester.tap(find.text('إضافة سطر عيار'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').last,
        '6',
      );
      await tester.pumpAndSettle();
      await execute(tester);
    });

    expect(sent, isEmpty);
    expect(find.textContaining('عيار 21k'), findsOneWidget);
  });

  testWidgets('the server\'s warning is said, not dropped', (tester) async {
    // A renewal whose stones' accounts are unset posts no stones entry, and
    // the server says so; the screen showed «تم بنجاح» alone.
    const warning = 'لم تُسجَّل قيود الفصوص المحاسبية';
    final sent = await run(warning: warning, tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      await execute(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'تأكيد التكسير'));
      await tester.pumpAndSettle();
    });

    expect(sent, hasLength(1));
    expect(find.textContaining(warning), findsOneWidget);
  });

  // خ٣ (ADR-050): the screen reads in the dark theme; its numbers are the
  // app's (thousands, a minus kept whole).
  for (final (name, size) in [
    ('desktop', const Size(1440, 1400)),
    ('tablet', tabletSize),
  ]) {
    testWidgets('it reads in the dark theme on a $name', (tester) async {
      await run(theme: DarkTheme.theme, size: size, tester, () async {
        await tester.enterText(
          find.widgetWithText(TextFormField, '0.000').first,
          '2',
        );
        await typeWage(tester);
        expect(tester.takeException(), isNull);
        await shot(tester, 'melting_dark_$name');
        expectNoTextVanishesOnDark(tester);
        expectNoLightSurfaceOnDark(tester);
      });
    });
  }

  // خ٤ (ADR-050): the keys of every document screen, and a form that asks
  // before what was typed in it is lost.
  Future<void> press(
    WidgetTester tester,
    LogicalKeyboardKey key, {
    bool control = false,
  }) async {
    // Out of a field, as the employee leaves it with Tab -- not out of the
    // screen's own scope, where its keys are heard.
    final focus = FocusManager.instance.primaryFocus;
    if (focus != null && focus is! FocusScopeNode) focus.unfocus();
    await tester.pump();
    if (control) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(key);
    if (control) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('Ctrl+Enter adds a karat line; Ctrl+S asks to execute', (
    tester,
  ) async {
    final sent = await run(tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      final lines = find.widgetWithText(TextFormField, '0.000');
      final before = lines.evaluate().length;
      await press(tester, LogicalKeyboardKey.enter, control: true);
      expect(lines.evaluate().length, before + 1);
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').last,
        '1',
      );
      await press(tester, LogicalKeyboardKey.keyS, control: true);
      expect(find.text('تأكيد التكسير'), findsWidgets);
    });
    expect(sent, isEmpty, reason: 'asked, not yet sent');
  });

  testWidgets('Esc asks before a typed weight is lost', (tester) async {
    await run(overAPage: true, tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('الخروج دون حفظ؟'), findsOneWidget);
      await tester.tap(find.text('البقاء'));
      await tester.pumpAndSettle();
      expect(find.byType(MeltingRenewalScreen), findsOneWidget);
    });
  });

  testWidgets('Esc on an untouched form leaves at once', (tester) async {
    await run(overAPage: true, tester, () async {
      await press(tester, LogicalKeyboardKey.escape);
      expect(find.text('الخروج دون حفظ؟'), findsNothing);
      expect(find.byType(MeltingRenewalScreen), findsNothing);
    });
  });
}
