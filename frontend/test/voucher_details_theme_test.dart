import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/voucher_details_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/shots.dart';

/// UI-5 (ADR-049): a voucher's details read in the dark theme too. Its text
/// was written black (Colors.black87 / black54) and vanished on the dark
/// background.
const _voucher = {
  'id': 7,
  'voucher_number': 'PV-2026-00011',
  'voucher_type': 'payment',
  'status': 'approved',
  'date': '2026-10-08T10:00:00',
  'party_type': 'supplier',
  'party_name': 'مورد الذهب',
  'receiver_name': 'مورد الذهب',
  'description': 'سداد دفعة للمورد مورد الذهب',
  'notes': 'دُفعت نقدًا في المحل',
  'amount_cash': 1500.0,
  'amount_gold': 0.0,
  'account_lines': [
    {
      'account_id': 70,
      'account_name': 'الصندوق',
      'account_number': '1110',
      'line_type': 'credit',
      'amount_type': 'cash',
      'amount': 1500.0,
    },
    {
      'account_id': 50,
      'account_name': 'مورد الذهب',
      'account_number': '2110',
      'line_type': 'debit',
      'amount_type': 'cash',
      'amount': 1500.0,
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

  for (final (name, theme) in [
    ('light', LightTheme.theme),
    ('dark', DarkTheme.theme),
  ]) {
    testWidgets('a voucher\'s details read in the $name theme', (tester) async {
      SharedPreferences.setMockInitialValues({
        'jwt_token': 'token',
        'app_settings': jsonEncode({'main_karat': 21}),
      });
      tester.view.physicalSize = const Size(1200, 2200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = SettingsProvider();
      await settings.loadSettings(fetchRemote: false);

      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            MultiProvider(
              providers: [
                ChangeNotifierProvider(create: (_) => AuthProvider()),
                ChangeNotifierProvider.value(value: settings),
              ],
              child: MaterialApp(
                theme: theme,
                home: const Directionality(
                  textDirection: TextDirection.rtl,
                  child: VoucherDetailsScreen(voucherId: 7),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        },
        () => MockClient((request) async {
          final body = request.url.path.endsWith('/vouchers/7')
              ? jsonEncode(_voucher)
              : '{}';
          return http.Response(
            body,
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      expect(find.text('PV-2026-00011'), findsWidgets);
      expect(find.text('سداد دفعة للمورد مورد الذهب'), findsWidgets);
      expect(tester.takeException(), isNull);
      await shot(tester, 'voucher_details_$name');

      if (theme.brightness == Brightness.dark) {
        // No text painted near-black on the dark theme.
        final dark = <String>[];
        for (final p in tester.renderObjectList<RenderParagraph>(
          find.byType(RichText),
        )) {
          final color = p.text.style?.color;
          if (color != null &&
              color.a > 0.5 &&
              color.computeLuminance() < 0.05) {
            dark.add(p.text.toPlainText());
          }
        }
        expect(dark, isEmpty, reason: 'text that vanishes on dark');
      }
    });
  }
}
