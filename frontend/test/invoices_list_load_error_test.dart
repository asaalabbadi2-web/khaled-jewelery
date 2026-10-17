import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/invoices_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// UI-4 (ADR-049): a list of invoices that failed to load says so and offers
/// to try again. It used to flash a snackbar and then read «لا توجد فواتير --
/// ابدأ بإضافة فاتورة جديدة», as if the shop had sold nothing.
void main() {
  testWidgets('a failed load is not «no invoices»', (tester) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1440, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);

    var asked = 0;
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MultiProvider(
            providers: [
              ChangeNotifierProvider(create: (_) => AuthProvider()),
              ChangeNotifierProvider.value(value: settings),
            ],
            child: MaterialApp(
              theme: LightTheme.theme,
              home: const Directionality(
                textDirection: TextDirection.rtl,
                child: InvoicesListScreen(),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('لا توجد فواتير'), findsNothing);
        expect(find.text('تعذّر تحميل الفواتير'), findsOneWidget);

        final before = asked;
        await tester.tap(find.text('إعادة المحاولة'));
        await tester.pumpAndSettle();
        expect(asked, greaterThan(before));
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/invoices')) asked++;
        return http.Response(
          '{"error": "server_error"}',
          500,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );
  });
}
