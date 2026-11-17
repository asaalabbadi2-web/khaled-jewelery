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
import 'support/dark_text.dart';
import 'support/machine_date.dart';

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

      // Its bar, in the voucher's color, reads (the owner, 17 Nov 2026: in
      // the dark it was the payment's light lavender under the theme's light
      // title -- «كأنه غير ملتزم بالثيم»).
      final bar = tester.widget<AppBar>(find.byType(AppBar));
      final title = tester.renderObject<RenderParagraph>(find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(RichText),
      ).first);
      final ink = title.text.style!.color!;
      final la = ink.computeLuminance(), lb = bar.backgroundColor!.computeLuminance();
      final ratio = ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
      expect(ratio, greaterThanOrEqualTo(4.5), reason: 'the bar\'s title on its color');
      expectNoMachineDate(tester);

      if (theme.brightness == Brightness.dark) {
        expectNoTextVanishesOnDark(tester);
      }
    });
  }

  testWidgets('an expense paid with a tax invoice says its invoice and its VAT '
      '(the owner, 20 Oct 2026)', (tester) async {
    SharedPreferences.setMockInitialValues({
      'jwt_token': 'token',
      'app_settings': jsonEncode({'main_karat': 21}),
    });
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = SettingsProvider();
    await settings.loadSettings(fetchRemote: false);
    final expense = {
      ..._voucher,
      'party_type': 'other',
      'party_name': 'كهرباء',
      'expense_vat': {
        'amount': 15.0,
        'supplier_name': 'شركة الكهرباء',
        'supplier_tax_number': '300000000000003',
        'invoice_number': 'F-1009',
        'invoice_date': '2026-10-19',
        'recoverable': true,
      },
    };
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
                child: VoucherDetailsScreen(voucherId: 7),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
      },
      () => MockClient((request) async => http.Response(
        request.url.path.endsWith('/vouchers/7') ? jsonEncode(expense) : '{}',
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      )),
    );
    expect(find.text('الفاتورة الضريبية'), findsOneWidget);
    expect(find.textContaining('شركة الكهرباء'), findsOneWidget);
    expect(find.textContaining('300000000000003'), findsOneWidget);
    expect(find.textContaining('F-1009'), findsOneWidget);
    expect(find.textContaining('15.00'), findsWidgets);
    expect(find.textContaining('مستردة'), findsOneWidget);
  });
}
