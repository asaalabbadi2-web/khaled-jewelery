import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/login_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_login_api.dart';

/// The sign-in says what stands in the way, as the server says it (the owner,
/// 10 Oct 2026). It called every refusal «اسم المستخدم أو كلمة المرور غير صحيحة»
/// -- too many attempts, an inactive account, a dead server -- cleared what was
/// typed, sent each wrong password twice (the old method posts the same route
/// again: three clicks locked a user out, not five), and had no field for the
/// verification code the server asks for.
void main() {
  setUpAll(() async {
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  // The focused field's border glows without end: time is moved, not awaited.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<AuthProvider> open(
    WidgetTester tester,
    FakeLoginApi api, {
    ThemeData? theme,
    Future<bool> Function()? ping,
  }) async {
    SharedPreferences.setMockInitialValues({
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final auth = AuthProvider(api: () => api);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: auth),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          theme: theme ?? LightTheme.theme,
          home: Directionality(
            textDirection: TextDirection.rtl,
            child: LoginScreen(pingServer: ping ?? () async => true),
          ),
        ),
      ),
    );
    await settle(tester);
    return auth;
  }

  Future<void> signIn(WidgetTester tester, {String user = 'ahmad', String pass = 'secret'}) async {
    await tester.enterText(find.byKey(const Key('login-username')), user);
    await tester.enterText(find.byKey(const Key('login-password')), pass);
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
  }

  String text(WidgetTester tester, String key) =>
      tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

  testWidgets('a wrong password is sent once, said once, and the password is cleared',
      (tester) async {
    final api = FakeLoginApi([FakeLoginApi.wrongPassword]);
    await open(tester, api);
    await signIn(tester);

    expect(api.sent, hasLength(1), reason: 'the old method must not re-post it');
    expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsOneWidget);
    expect(text(tester, 'login-password'), '');
    expect(text(tester, 'login-username'), 'ahmad');
  });

  testWidgets('too many attempts: the server\'s words, and the button waits, saying how long',
      (tester) async {
    final api = FakeLoginApi([FakeLoginApi.tooMany, 'ok']);
    await open(tester, api);
    await signIn(tester);

    expect(find.text(FakeLoginApi.tooMany.message), findsOneWidget);
    expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsNothing);
    expect(find.textContaining('انتظر 60 ثانية'), findsOneWidget);
    expect(text(tester, 'login-password'), 'secret', reason: 'nothing was wrong with it');

    await tester.tap(find.byKey(const Key('login-submit')), warnIfMissed: false);
    await tester.pump();
    expect(api.sent, hasLength(1), reason: 'a click during the wait asks the server nothing');

    await tester.pump(const Duration(seconds: 61));
    expect(find.text('دخول النظام'), findsOneWidget);
    expect(find.text(FakeLoginApi.tooMany.message), findsNothing);
  });

  testWidgets('an inactive account is said as the server says it', (tester) async {
    await open(tester, FakeLoginApi([FakeLoginApi.inactive]));
    await signIn(tester);
    expect(find.text('هذا الحساب غير نشط'), findsOneWidget);
  });

  testWidgets('nobody answers: said so, and what was typed stays', (tester) async {
    final api = FakeLoginApi([FakeLoginApi.nobodyAnswers]);
    await open(tester, api);
    await signIn(tester);

    expect(find.textContaining('تعذّر الاتصال بالخادم'), findsOneWidget);
    expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsNothing);
    expect(text(tester, 'login-password'), 'secret');
    expect(find.textContaining('غير متصل'), findsOneWidget);
  });

  testWidgets('an account that asks for its code gets the field, keeps its password, '
      'and the code is sent with the sign-in', (tester) async {
    final api = FakeLoginApi([FakeLoginApi.otpRequired, 'ok']);
    final auth = await open(tester, api);
    await signIn(tester);

    expect(find.byKey(const Key('login-otp')), findsOneWidget);
    expect(text(tester, 'login-password'), 'secret');
    expect(find.text('اسم المستخدم أو كلمة المرور غير صحيحة'), findsNothing);

    await tester.enterText(find.byKey(const Key('login-otp')), '123456');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(api.sent.last.otp, '123456');
    expect(api.sent.first.otp, isNull);
    expect(auth.isAuthenticated, isTrue);
  });

  testWidgets('a wrong code is said under the code, and cleared', (tester) async {
    final api = FakeLoginApi([FakeLoginApi.otpRequired, FakeLoginApi.otpInvalid]);
    await open(tester, api);
    await signIn(tester);
    await tester.enterText(find.byKey(const Key('login-otp')), '000000');
    await tester.tap(find.byKey(const Key('login-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('رمز التحقق غير صحيح'), findsOneWidget);
    expect(text(tester, 'login-otp'), '');
    expect(text(tester, 'login-password'), 'secret');
  });

  testWidgets('an offline server is not a dead end: tapping its state asks again', (tester) async {
    var asked = 0;
    var online = false;
    await open(tester, FakeLoginApi([]), ping: () async {
      asked++;
      return online;
    });
    expect(find.textContaining('غير متصل'), findsOneWidget);

    online = true;
    await tester.tap(find.byKey(const Key('login-server-status')));
    await settle(tester);
    expect(asked, 2);
    expect(find.textContaining('متصل'), findsOneWidget);
    expect(find.textContaining('غير متصل'), findsNothing);
  });

  testWidgets('it is drawn from the theme: in the dark mode the words are the theme\'s',
      (tester) async {
    await open(tester, FakeLoginApi([]), theme: DarkTheme.theme);
    final scheme = Theme.of(tester.element(find.byKey(const Key('login-username')))).colorScheme;
    final field = tester.widget<TextField>(find.byKey(const Key('login-username')));
    expect(field.style?.color, scheme.onSurface);
    final submit = tester.widget<ElevatedButton>(
      find.ancestor(of: find.text('دخول النظام'), matching: find.byWidgetPredicate((w) => w is ElevatedButton)).first,
    );
    expect(submit.style?.backgroundColor?.resolve({}), scheme.primary);
    expect(submit.style?.foregroundColor?.resolve({}), scheme.onPrimary);
  });
}
