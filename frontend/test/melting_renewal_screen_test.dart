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
      'stock_location': 'showroom',
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
      'stock_location': 'scrap',
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

/// The showroom's categories, one a karat, and a scrap one no line may name
/// (ت3).
const _categories = [
  {'id': 7, 'name': 'بنجرة اختبار 21', 'karat': '21', 'is_scrap': false},
  {'id': 8, 'name': 'خاتم اختبار 18', 'karat': '18', 'is_scrap': false},
  {'id': 9, 'name': 'كسر 21', 'karat': '21', 'is_scrap': true},
];

/// What the server would post: the confirmation shows these, not a summary
/// of its own (ت2).
const _previewLines = [
  {
    'account_number': '71300',
    'account_name': 'المعروض وزني',
    'side': 'credit',
    'amount_type': 'gold',
    'amount': 2.0,
    'karat': 21,
  },
  {
    'account_number': '5410',
    'account_name': 'مصنعية تالفة (الدور)',
    'side': 'debit',
    'amount_type': 'cash',
    'amount': 100.0,
    'karat': null,
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
    Map<String, dynamic>? safes,
    Map<String, dynamic>? previewRefusal,
    ThemeData? theme,
    Size size = const Size(1200, 2400),
    bool overAPage = false,
    int mainKarat = 21,
    int failingLoads = 0,
  }) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': mainKarat}),
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
        if (path.endsWith('/safe-boxes/balances') && failingLoads > 0) {
          failingLoads--;
          return http.Response(
            jsonEncode({'error': 'الخادم مشغول'}),
            500,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
        if (request.method == 'POST' &&
            path.endsWith('/melting-renewal/preview')) {
          // The server's entry before it is saved (ت2).
          if (previewRefusal != null) {
            return http.Response(
              jsonEncode(previewRefusal),
              400,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({'preview': true, 'lines': _previewLines}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }
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
            ? (safes ?? _safes)
            : path.endsWith('/categories')
            ? _categories
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

  /// Each line its category (ت3): the one of its karat.
  Future<void> pickCategories(WidgetTester tester) async {
    final fields = find.widgetWithText(
      DropdownButtonFormField<int>,
      'تصنيف ما يُكسَّر',
    );
    for (var i = 0; i < fields.evaluate().length; i++) {
      await tester.ensureVisible(fields.at(i));
      await tester.tap(fields.at(i));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('اختبار').last);
      await tester.pumpAndSettle();
    }
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
      await pickCategories(tester);
      await execute(tester);
      // The confirmation is the server's entry (ت2).
      expect(find.textContaining('مصنعية تالفة (الدور)'), findsOneWidget);
      expect(find.textContaining('مدين'), findsWidgets);
      await tester.tap(find.widgetWithText(FilledButton, 'تأكيد التكسير'));
      await tester.pumpAndSettle();
    });

    expect(sent, hasLength(1), reason: 'one operation, one request');
    expectPayload('melting_two_karats', sent.single);
    expect(find.textContaining('ADJ-2026-00042'), findsOneWidget);
    expect(find.text('عرض السند'), findsOneWidget);
  });

  testWidgets('a wage with its role unmapped is said and nothing is sent', (
    tester,
  ) async {
    // The wage's account is its role's (ت2): unmapped, the server's preview
    // refuses saying where it is set, and the operation is not sent.
    const said = 'حساب «المصنعية التالفة بالتكسير» غير مربوط';
    final sent = await run(
      previewRefusal: {'error': 'account_not_mapped', 'message': said},
      tester,
      () async {
        await tester.enterText(
          find.widgetWithText(TextFormField, '0.000').first,
          '2',
        );
        await typeWage(tester);
        await pickCategories(tester);
        await execute(tester);
      },
    );

    expect(sent, isEmpty);
    expect(find.textContaining(said), findsOneWidget);
    expect(find.text('تأكيد التكسير'), findsNothing);
  });

  testWidgets('a line names a category of its karat, never a scrap one', (
    tester,
  ) async {
    // ت3: the line's gold leaves the showroom under its category; the scrap
    // side is the server's. No category, nothing is sent.
    final sent = await run(tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      await execute(tester);
      expect(find.text('اختر التصنيف'), findsOneWidget);
      expect(find.text('تأكيد التكسير'), findsNothing);

      final field = find.widgetWithText(
        DropdownButtonFormField<int>,
        'تصنيف ما يُكسَّر',
      );
      await tester.ensureVisible(field);
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(find.textContaining('بنجرة اختبار 21'), findsWidgets);
      expect(find.textContaining('خاتم اختبار 18'), findsNothing);
      expect(find.text('كسر 21'), findsNothing);
      await tester.tap(find.textContaining('بنجرة اختبار 21').last);
      await tester.pumpAndSettle();
    });

    expect(sent, isEmpty);
  });

  testWidgets('a melting weighs its stones with its gold (ت5)', (tester) async {
    // The showroom holds its stones as gold: 6 g of gold and 5 g of stones
    // are 11 g of the 10 g held -- refused, nothing sent.
    final sent = await run(tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '6',
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, 'فصوص، حديد…').first,
        '5',
      );
      await tester.pumpAndSettle();
      await pickCategories(tester);
      await execute(tester);
    });

    expect(sent, isEmpty);
    expect(find.textContaining('عيار 21k'), findsOneWidget);
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
      await pickCategories(tester);
      await execute(tester);
    });

    expect(sent, isEmpty);
    expect(find.textContaining('عيار 21k'), findsOneWidget);
  });

  testWidgets(
    'melting goes to a scrap safe by its kind, not a name with «كسر»',
    (tester) async {
      // ت1: the target was the first safe whose name held «كسر» -- here a
      // showroom. A showroom is no melting's target; the scrap safe is.
      Map<String, dynamic> safe(
        int id,
        String name,
        String location,
        double g21,
      ) => {
        'id': id,
        'name': name,
        'safe_type': 'gold',
        'stock_location': location,
        'account_id': 700 + id,
        'balance': {
          'cash': 0.0,
          'weight': {
            '18k': 0.0,
            '21k': g21,
            '22k': 0.0,
            '24k': 0.0,
            'total': g21,
          },
        },
      };
      final sent = await run(
        safes: {
          'rows': [
            safe(3, 'معرض الكسر القديم', 'showroom', 10.0),
            safe(1, 'الذهب المعروض', 'showroom', 10.0),
            safe(2, 'الخزينة الرئيسية', 'scrap', 0.0),
          ],
        },
        tester,
        () async {
          await tester.enterText(
            find.widgetWithText(TextFormField, '0.000').first,
            '2',
          );
          await pickCategories(tester);
          await execute(tester);
          await tester.tap(find.widgetWithText(FilledButton, 'تأكيد التكسير'));
          await tester.pumpAndSettle();
        },
      );

      expect(sent, hasLength(1));
      expect(sent.single['from_safe_box_id'], 3);
      expect(sent.single['to_safe_box_id'], 2);
    },
  );

  testWidgets('the server\'s warning is said, not dropped', (tester) async {
    // What the server warns of is said; the screen showed «تم بنجاح» alone.
    // (Its one warning, a renewal's unposted stones entry, went with that
    // entry in ت1 -- the contract stays for any.)
    const warning = 'تحذير من الخادم';
    final sent = await run(warning: warning, tester, () async {
      await tester.enterText(
        find.widgetWithText(TextFormField, '0.000').first,
        '2',
      );
      await pickCategories(tester);
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
      await pickCategories(tester);
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

  // ر٥ (ADR-057): the owner, 23 Oct 2026 -- the header's text did not read.
  // The chosen tab was the light bar's own gold; the screen was witnessed
  // only in the dark.
  testWidgets('the chosen tab reads on the light theme\'s bar', (tester) async {
    await run(tester, () async {
      final bar = LightTheme.theme.appBarTheme;
      final tabs = tester.widget<TabBar>(find.byType(TabBar));
      expect(tabs.labelColor, bar.foregroundColor);
      expect(tabs.labelColor, isNot(bar.backgroundColor));
    });
  });

  testWidgets('a load that fails says so, with a retry, and no form', (
    tester,
  ) async {
    await run(failingLoads: 1, tester, () async {
      expect(find.text('إعادة المحاولة'), findsOneWidget);
      expect(find.text('تنفيذ التكسير'), findsNothing);
      expect(find.text('0.000'), findsNothing);
      await tester.tap(find.text('إعادة المحاولة'));
      await tester.pumpAndSettle();
      expect(find.text('تنفيذ التكسير'), findsOneWidget);
    });
  });

  testWidgets('no scrap safe: it says why and where it is set', (tester) async {
    final showroomOnly = {
      'rows': [(_safes['rows'] as List).first],
    };
    await run(safes: showroomOnly, tester, () async {
      expect(find.text('لا خزينة كسر'), findsOneWidget);
      expect(find.text('إدارة الخزائن'), findsOneWidget);
      expect(find.text('تنفيذ التكسير'), findsNothing);
    });
  });

  testWidgets('on a phone the safes stack and nothing overflows', (
    tester,
  ) async {
    await run(size: const Size(390, 844), tester, () async {
      expect(tester.takeException(), isNull);
      final from = tester.getTopLeft(find.text('خزينة المصدر'));
      final to = tester.getTopLeft(find.text('خزينة الوجهة'));
      expect(to.dy, greaterThan(from.dy));
    });
  });

  testWidgets('a line on an empty source is of the main karat', (tester) async {
    final empty = {
      'rows': [
        for (final row in _safes['rows'] as List)
          {
            ...(row as Map<String, dynamic>),
            'balance': {
              'cash': 0.0,
              'weight': {'18k': 0.0, '21k': 0.0, '22k': 0.0, '24k': 0.0, 'total': 0.0},
            },
          },
      ],
    };
    await run(safes: empty, mainKarat: 18, tester, () async {
      expect(
        tester
            .widget<DropdownButtonFormField<int>>(
              find.byType(DropdownButtonFormField<int>).at(2),
            )
            .initialValue,
        18,
      );
    });
  });

  // The owner, 23 Oct 2026: «خانة واحدة لكل ما هو غير ذهب سواء بالتجديد أو
  // التكسير» -- the field said «فصوص» alone; iron and a clasp had no place.
  testWidgets('one field takes what is not gold, in both operations', (
    tester,
  ) async {
    await run(tester, () async {
      expect(find.text('غير الذهب (جم)'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'فصوص، حديد…'), findsOneWidget);
      await tester.tap(find.text('تجديد القطع'));
      await tester.pumpAndSettle();
      expect(find.text('غير الذهب (جم)'), findsOneWidget);
      expect(find.widgetWithText(TextFormField, 'فصوص، حديد…'), findsOneWidget);
    });
  });

  // The confirmation said «(وزن، لا قيد)» under an entry that posts them
  // (ت5, ت5أ): it says the server's entry alone.
  testWidgets('the confirmation says no line the entry does not post', (
    tester,
  ) async {
    await run(tester, () async {
      await tester.enterText(find.widgetWithText(TextFormField, '0.000').first, '2');
      await tester.enterText(
        find.widgetWithText(TextFormField, 'فصوص، حديد…').first,
        '1',
      );
      await pickCategories(tester);
      await execute(tester);
      expect(find.text('تأكيد التكسير'), findsWidgets);
      expect(find.textContaining('لا قيد'), findsNothing);
    });
  });
}
