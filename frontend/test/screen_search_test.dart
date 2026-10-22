import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:frontend/providers/sales_race_refresh_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/customize_quick_actions_screen.dart';
import 'package:frontend/screens/home_screen_enhanced.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/app_screen_search.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/dark_text.dart';
import 'support/shots.dart';

/// ADR-057 ق٠: the home screen's header finds any screen of the app -- the
/// side menu's, the reports', and those opened from inside another screen
/// (the owner: «الشاشات ليست كلها موجودة في القائمة الجانبية») -- by its name
/// or the words people use for it, written as people write them; each held to
/// what the user may open. And the side menu keeps the sections left open.
class _Manager extends AuthProvider {
  @override
  String get username => 'manager';
  @override
  String get role => 'manager';
  @override
  bool hasPermission(String key) => true;
}

/// The system admin: the reset is theirs.
class _Admin extends _Manager {
  @override
  String get role => 'system_admin';
}

/// Counts the sign-outs it is asked for.
class _Leaving extends _Manager {
  int logouts = 0;
  @override
  Future<void> logout() async => logouts++;
}

/// A seller holds no report, voucher or safe permission.
class _Seller extends AuthProvider {
  @override
  String get username => 'seller';
  @override
  String get role => 'employee';
  @override
  bool hasPermission(String key) => false;
}

ScreenDestination _d(String title, {List<String> keywords = const []}) =>
    ScreenDestination(
      title: title,
      section: 'قسم',
      icon: Icons.circle,
      keywords: keywords,
      open: () async {},
    );

void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  group('matching', () {
    test('finds a name as people write it, a title that starts with it '
        'first', () {
      final found = matchDestinations([
        _d('جميع الفواتير'),
        _d('فاتورة بيع'),
        _d('قائمة العملاء'),
      ], 'فاتوره');
      expect(found.map((d) => d.title), ['فاتورة بيع']);

      final both = matchDestinations([
        _d('جميع الفواتير'),
        _d('فواتير معلقة'),
      ], 'فواتير');
      expect(both.map((d) => d.title), ['فواتير معلقة', 'جميع الفواتير']);
    });

    test('finds by the words people use, and shows one screen once', () {
      final found = matchDestinations([
        _d('قائمة الدخل', keywords: ['أرباح']),
        _d('ميزان المراجعة'),
        _d('ميزان المراجعة'),
      ], 'ارباح');
      expect(found.map((d) => d.title), ['قائمة الدخل']);
      expect(matchDestinations([
        _d('ميزان المراجعة'),
        _d('ميزان المراجعة'),
      ], 'ميزان'), hasLength(1));
    });
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> openHome(
    WidgetTester tester, {
    AuthProvider? auth,
    Size size = const Size(1440, 1000),
    ThemeData? theme,
    Map<String, Object> prefs = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'main_karat': 21}),
      ...prefs,
    });
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>(
            create: (_) => auth ?? _Manager(),
          ),
          ChangeNotifierProvider.value(value: settings),
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider(create: (_) => QuickActionsProvider()),
          ChangeNotifierProvider(create: (_) => SalesRaceRefreshProvider()),
        ],
        child: MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: const Directionality(
            textDirection: TextDirection.rtl,
            child: HomeScreenEnhanced(),
          ),
        ),
      ),
    );
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  }

  Future<void> search(WidgetTester tester, String query) async {
    await tester.enterText(find.byKey(const Key('screen-search-field')), query);
    await settle(tester);
  }

  // A result, not the field's own text.
  Finder result(String title) => find.descendant(
    of: find.byType(Dialog),
    matching: find.descendant(
      of: find.byType(ListView),
      matching: find.text(title),
    ),
  );

  testWidgets('a wide screen\'s header has the field; it opens the search', (
    tester,
  ) async {
    await openHome(tester);
    expect(find.text('ابحث عن شاشة…'), findsOneWidget);
    await shot(tester, 'home_header_desktop');
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);
    expect(find.byKey(const Key('screen-search-field')), findsOneWidget);
    await search(tester, 'كشف');
    await shot(tester, 'screen_search_desktop');
  });

  testWidgets('Ctrl+K opens it, and Esc closes it', (tester) async {
    await openHome(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(find.byKey(const Key('screen-search-field')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const Key('screen-search-field')), findsNothing);
  });

  testWidgets('it finds screens the side menu does not hold', (tester) async {
    await openHome(tester);
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);

    // A report, by a word of its own («ضريبة»), and by a word people use.
    await search(tester, 'ضريبه');
    expect(result('إقرارات ضريبة القيمة المضافة'), findsOneWidget);
    await search(tester, 'ارباح');
    expect(result('قائمة الدخل'), findsOneWidget);

    // A page opened from inside the settings.
    await search(tester, 'الربط المحاسبي');
    expect(result('الربط المحاسبي'), findsOneWidget);

    // And the menu's, too.
    await search(tester, 'سند قبض');
    expect(result('سند قبض'), findsOneWidget);

    // «فاتورة» finds the invoices whose names do not say it.
    await search(tester, 'فاتورة');
    expect(result('شراء جديد'), findsOneWidget);
    expect(result('مرتجع بيع'), findsOneWidget);
  });

  testWidgets('a seller finds only what a seller may open', (tester) async {
    await openHome(tester, auth: _Seller());
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);
    await search(tester, 'فاتورة بيع');
    expect(result('فاتورة بيع'), findsOneWidget);
    for (final q in ['ضريبة', 'سند قبض', 'الربط المحاسبي', 'إدارة الخزائن']) {
      await search(tester, q);
      expect(
        find.byKey(const Key('screen-search-empty')),
        findsOneWidget,
        reason: '«$q» is not the seller\'s',
      );
    }
  });

  testWidgets('Enter opens the first; it is then the first of the recent', (
    tester,
  ) async {
    await openHome(tester);
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);
    await search(tester, 'تخصيص الوصول');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(find.byType(CustomizeQuickActionsScreen), findsOneWidget);

    Navigator.of(tester.element(find.byType(CustomizeQuickActionsScreen)))
        .pop();
    await settle(tester);
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);
    expect(result('آخر ما فتحته'), findsOneWidget);
    expect(result('تخصيص الوصول السريع'), findsOneWidget);
  });

  testWidgets('↓ chooses the next result, and Enter opens it', (tester) async {
    await openHome(tester);
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);
    await search(tester, 'مرتجع');
    final second = tester.widget<ListTile>(
      find.byKey(const Key('screen-search-result-1')),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('screen-search-result-1')))
          .selected,
      isTrue,
    );
    expect(second.selected, isFalse);
  });

  testWidgets('a phone has the icon, and the search takes the screen', (
    tester,
  ) async {
    await openHome(tester, size: const Size(390, 844));
    expect(find.text('ابحث عن شاشة…'), findsNothing);
    await tester.tap(find.byKey(const Key('screen-search-open')));
    await settle(tester);
    await search(tester, 'مرتجع');
    final dialog = tester.getSize(find.byType(Dialog));
    expect(dialog.width, 390);
    expect(tester.takeException(), isNull);
    await shot(tester, 'screen_search_phone');
  });

  for (final (name, size) in [
    ('desktop', const Size(1440, 1000)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('the search reads in the dark theme on a $name', (
      tester,
    ) async {
      await openHome(tester, size: size, theme: DarkTheme.theme);
      await tester.tap(find.byKey(const Key('screen-search-open')));
      await settle(tester);
      await search(tester, 'فاتورة');
      expect(tester.takeException(), isNull);
      await shot(tester, 'screen_search_dark_$name');
      expectNoTextVanishesOnDark(tester, within: find.byType(Dialog));
    });
  }

  // On HEAD a phone overflowed twice: the header's icons by 16px, and the
  // sales race's period beside its title by 7px.
  testWidgets('the home screen fits a phone, header and race card', (
    tester,
  ) async {
    await openHome(tester, size: const Size(390, 844));
    expect(tester.takeException(), isNull);
    // The logo alone: the name would be cut to «مج…».
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('مجوهرات خالد'),
      ),
      findsNothing,
    );
    await shot(tester, 'home_phone');
  });

  testWidgets('the user menu has a name', (tester) async {
    await openHome(tester);
    expect(find.byTooltip('قائمة المستخدم'), findsOneWidget);
  });

  group('the side menu', () {
    Future<void> openDrawer(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await settle(tester);
    }

    Finder inDrawer(String text) => find.descendant(
      of: find.byType(Drawer),
      matching: find.text(text),
    );

    testWidgets('keeps the sections left open, on this device', (
      tester,
    ) async {
      await openHome(
        tester,
        prefs: {
          'drawer_open_sections': ['المرتجعات'],
        },
      );
      await openDrawer(tester);
      expect(inDrawer('مرتجع بيع'), findsOneWidget);
      expect(inDrawer('فاتورة بيع'), findsNothing);

      await tester.tap(inDrawer('الفواتير'));
      await settle(tester);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('drawer_open_sections'),
        containsAll(['المرتجعات', 'الفواتير']),
      );
    });

    testWidgets('its header is the shop and the user; the account\'s pages '
        'are the user menu\'s', (tester) async {
      await openHome(tester);
      await openDrawer(tester);
      expect(find.byType(ActionChip), findsNothing);
      expect(inDrawer('الدور: مدير'), findsOneWidget);
    });

    testWidgets('a user with no role has no empty «الدور:» line', (
      tester,
    ) async {
      await openHome(tester, auth: AuthProvider());
      await openDrawer(tester);
      expect(find.textContaining('الدور:'), findsNothing);
    });

    testWidgets('on a phone it leaves a strip of the screen beside it', (
      tester,
    ) async {
      await openHome(tester, size: const Size(390, 844));
      await openDrawer(tester);
      expect(tester.getSize(find.byType(Drawer)).width, lessThan(390 * 0.9));
      expect(tester.takeException(), isNull);
    });
  });

  // ق١ (ADR-057): the menus say themselves plainly.
  group('the side menu, ق١', () {
    Future<void> openDrawer(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.menu_rounded));
      await settle(tester);
    }

    testWidgets('every section title is in one colour', (tester) async {
      await openHome(tester);
      await openDrawer(tester);
      Color? colorOf(String title) => tester
          .widget<Text>(
            find.descendant(
              of: find.byType(ExpansionTile),
              matching: find.text(title),
            ),
          )
          .style
          ?.color;
      final onSurface = Theme.of(
        tester.element(find.byType(Drawer)),
      ).colorScheme.onSurface;
      for (final t in ['الفواتير', 'المرتجعات', 'الإعدادات والنظام']) {
        await tester.scrollUntilVisible(
          find.descendant(
            of: find.byType(ExpansionTile),
            matching: find.text(t),
          ),
          200,
          scrollable: find.descendant(
            of: find.byType(Drawer),
            matching: find.byType(Scrollable),
          ),
        );
        expect(colorOf(t), onSurface, reason: t);
      }
    });

    testWidgets('the system reset stands apart at the bottom, in the error\'s '
        'tone', (tester) async {
      await openHome(tester, auth: _Admin());
      await openDrawer(tester);
      final reset = find.byKey(const Key('drawer-danger-إعادة تهيئة النظام'));
      await tester.scrollUntilVisible(
        reset,
        200,
        scrollable: find.descendant(
          of: find.byType(Drawer),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        find.ancestor(of: reset, matching: find.byType(ExpansionTile)),
        findsNothing,
        reason: 'not one line among the settings',
      );
      final error = Theme.of(tester.element(reset)).colorScheme.error;
      expect(
        tester
            .widget<Text>(
              find.descendant(
                of: reset,
                matching: find.text('إعادة تهيئة النظام'),
              ),
            )
            .style
            ?.color,
        error,
      );
      // Below every section.
      final lastSection = tester.getRect(find.byType(ExpansionTile).last);
      expect(tester.getRect(reset).top, greaterThan(lastSection.bottom));
      await shot(tester, 'drawer_admin_bottom');
    });

    testWidgets('a manager has no reset', (tester) async {
      await openHome(tester);
      await openDrawer(tester);
      expect(find.textContaining('إعادة تهيئة النظام'), findsNothing);
    });
  });

  group('the user menu', () {
    Future<void> chooseLogout(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('user-menu')));
      await settle(tester);
      await tester.tap(find.text('تسجيل الخروج'));
      await settle(tester);
    }

    testWidgets('signing out asks first; going back keeps the session', (
      tester,
    ) async {
      final auth = _Leaving();
      await openHome(tester, auth: auth);
      await chooseLogout(tester);
      expect(find.text('تسجيل الخروج؟'), findsOneWidget);
      await tester.tap(find.text('تراجع'));
      await settle(tester);
      expect(auth.logouts, 0);

      await chooseLogout(tester);
      await tester.tap(find.byKey(const Key('confirm-action')));
      await settle(tester);
      expect(auth.logouts, 1);
    });

    testWidgets('no profile item where it cannot open', (tester) async {
      await openHome(tester);
      await tester.tap(find.byKey(const Key('user-menu')));
      await settle(tester);
      expect(find.text('ملف المستخدم'), findsNothing);
      expect(find.text('تغيير كلمة المرور'), findsOneWidget);
    });
  });
}
