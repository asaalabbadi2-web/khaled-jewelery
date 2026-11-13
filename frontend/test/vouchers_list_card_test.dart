// A voucher's card in the list (the owner, 13 Nov 2026: «اعد تصميم بطاقات قائمة
// السندات»): what it is and its number above, what it moved large, who and
// when; approving a pending one stays in sight, editing, cancelling and
// deleting wait in its menu; a cancelled one has no menu and stands back.
// Made-up vouchers.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/vouchers_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _voucher(int id, String status, {double cash = 15000.5}) => {
      'id': id, 'voucher_number': 'RV-2026-0000$id', 'voucher_type': 'receipt', 'status': status,
      'date': '2026-11-1${id}T09:00:00', 'amount_cash': cash, 'amount_gold': 0.0, 'amount_gold_main_karat': 0.0,
      'gold_karat': 21, 'main_karat': 21, 'description': 'سند تجريبي $id', 'party_name': 'طرف تجريبي $id',
      'party_type': 'customer', 'created_by': 'موظف', 'account_lines': [], 'gold_breakdown': {},
      'reference_type': null, 'notes': '',
    };

Future<void> _open(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'auth_current_user': jsonEncode(AppUserModel.fromJson({
      'id': 3, 'username': 'manager', 'full_name': 'مدير', 'role': 'manager', 'is_active': true, 'is_admin': false,
      'employee_id': 15, 'permissions': null, 'must_change_password': false,
      'effective_permissions': const ['vouchers.view', 'vouchers.create', 'vouchers.edit', 'vouchers.approve'],
    }).toStorageMap()),
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = const Size(390, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final auth = AuthProvider();
  await auth.init();
  await http.runWithClient(
    () async {
      await tester.pumpWidget(MultiProvider(
        providers: [
          ChangeNotifierProvider<AuthProvider>.value(value: auth),
          ChangeNotifierProvider.value(value: settings),
        ],
        child: MaterialApp(
          theme: LightTheme.theme,
          home: const Directionality(textDirection: TextDirection.rtl, child: VouchersListScreen()),
        ),
      ));
      for (var i = 0; i < 15; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
    },
    () => MockClient((request) async {
      final body = request.url.path.endsWith('/vouchers')
          ? {
              'current_page': 1, 'pages': 1, 'per_page': 20, 'total': 3, 'cancelled_hidden': {},
              'available_creators': [], 'available_parties': [], 'current_summary': {},
              'vouchers': [_voucher(1, 'pending'), _voucher(2, 'approved'), _voucher(3, 'cancelled')],
            }
          : (request.url.path.contains('customers') || request.url.path.contains('suppliers') ? [] : {});
      return http.Response.bytes(utf8.encode(jsonEncode(body)), 200,
          headers: {'content-type': 'application/json; charset=utf-8'});
    }),
  );
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('ar');
    await initializeDateFormatting('en');
    final cairo = FontLoader('Cairo');
    for (final w in ['Regular', 'SemiBold', 'Bold']) {
      cairo.addFont(rootBundle.load('assets/fonts/Cairo-$w.ttf'));
    }
    await cairo.load();
  });

  testWidgets('a pending one: approving in sight, the rest in its menu', (tester) async {
    await _open(tester);
    expect(tester.takeException(), isNull);
    final pending = find.byKey(const ValueKey('voucher-card-1'));
    expect(pending, findsOneWidget);
    expect(find.descendant(of: pending, matching: find.byKey(const ValueKey('voucher-approve-1'))), findsOneWidget);
    expect(find.descendant(of: pending, matching: find.byKey(const ValueKey('voucher-menu-1'))), findsOneWidget);
    for (final action in ['تعديل', 'إلغاء', 'حذف']) {
      expect(find.descendant(of: pending, matching: find.text(action)), findsNothing, reason: '«$action» waits in the menu');
    }
    expect(find.descendant(of: pending, matching: find.textContaining('15,000.50')), findsOneWidget, reason: 'what it moved');
    expect(find.descendant(of: pending, matching: find.text('طرف تجريبي 1')), findsOneWidget, reason: 'who');

    await tester.tap(find.byKey(const ValueKey('voucher-menu-1')));
    await tester.pumpAndSettle();
    for (final action in ['تعديل', 'إلغاء', 'حذف']) {
      expect(find.text(action), findsOneWidget, reason: '«$action» in the menu');
    }
  });

  testWidgets('an approved one: no approving; a cancelled one: no menu, standing back', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('voucher-approve-2')), findsNothing);
    expect(find.byKey(const ValueKey('voucher-menu-2')), findsOneWidget);
    await tester.drag(find.byType(Scrollable).last, const Offset(0, -600));
    await tester.pump();
    final cancelled = find.byKey(const ValueKey('voucher-card-3'));
    expect(cancelled, findsOneWidget);
    expect(find.byKey(const ValueKey('voucher-menu-3')), findsNothing);
    expect(find.ancestor(of: cancelled, matching: find.byType(Opacity)), findsWidgets);
  });
}
