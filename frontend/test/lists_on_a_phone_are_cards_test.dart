// On a phone a list's rows are cards, not a table (the owner, 13 Nov 2026: «في
// الشاشات الصغيره اجعل العرض كبطاقات وليس جداول واسطر ... وتأكد من سلامة
// العرض»). From a tablet up the table stays; the list's toggle still changes
// it. Each list drawn at an iPhone SE, an iPhone and an iPad mini: nothing
// overflows. The rows are made up here -- no shop's data.
//
// The toggle offers the other view: on cards it offers the table
// (Icons.table_rows_outlined) -- that is how the view drawn is read.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/app_user_model.dart';
import 'package:frontend/providers/auth_provider.dart';
import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/invoices_list_screen.dart';
import 'package:frontend/screens/journal_entries_list_screen.dart';
import 'package:frontend/screens/vouchers_list_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _sizes = <String, Size>{
  'iPhone SE': Size(375, 667),
  'iPhone': Size(390, 844),
  'iPad mini': Size(744, 1133),
};

Map<String, dynamic> _invoice(int i) => {
      'id': i, 'invoice_number': 'SELL-2026-0000$i', 'invoice_type': i == 2 ? 'شراء من عميل' : 'بيع',
      'invoice_type_label': i == 2 ? 'شراء كسر' : 'بيع', 'date': '2026-11-1${i}T10:30:00',
      'customer_name': 'عميل تجريبي بأسماء طويلة للتحقق من الالتفاف $i', 'customer_id': i,
      'total': 12345.67 * i, 'amount_paid': 12345.67 * i, 'total_tax': 1610.3, 'is_posted': true,
      'status': 'paid', 'posted_by': 'موظف تجريبي', 'employee_name': 'موظف تجريبي', 'gold_type': 'new',
      'total_weight': 25.75 * i, 'total_weight_main_karat': 25.75 * i, 'items': [], 'payments': [],
      'karat_lines': [], 'returns': [], 'barter_total': 0.0, 'cash_obligation': 0.0,
    };

Map<String, dynamic> _voucher(int i) => {
      'id': i, 'voucher_number': 'RV-2026-0000$i', 'voucher_type': i == 2 ? 'payment' : 'receipt',
      'status': 'active', 'date': '2026-11-1${i}T09:00:00', 'amount_cash': 15000.5 * i,
      'amount_gold': i == 3 ? 12.345 : 0.0, 'amount_gold_main_karat': i == 3 ? 12.345 : 0.0, 'gold_karat': 21,
      'main_karat': 21, 'description': 'سند تجريبي بوصف طويل يحتاج أكثر من سطر على شاشة الهاتف $i',
      'party_name': 'طرف تجريبي $i', 'party_type': 'customer', 'created_by': 'موظف تجريبي',
      'account_lines': [], 'gold_breakdown': {}, 'reference_type': null, 'notes': '',
    };

Map<String, dynamic> _entry(int i) => {
      'id': i, 'entry_number': 'JE-2026-0000$i', 'entry_type': 'عادي', 'date': '2026-11-1${i}T08:00:00',
      'description': 'قيد تجريبي بوصف طويل يتجاوز عرض الهاتف ليتأكد الالتفاف $i', 'cash_total': 2500.75 * i,
      'gold_total_main_karat': 12.5 * i, 'is_posted': true, 'creator_name': 'موظف تجريبي',
      'created_by': 'موظف تجريبي', 'accounts_preview': ['صندوق النقدية الرئيسي', 'مبيعات ذهب', 'ضريبة القيمة المضافة'],
      'line_count': 3, 'reference_display': null, 'reference_type': null, 'notes': '',
    };

Object _answer(String path) {
  if (path.endsWith('/invoices')) {
    return {'current_page': 1, 'pages': 1, 'per_page': 50, 'total': 3, 'meta': {},
            'invoices': [for (var i = 1; i <= 3; i++) _invoice(i)]};
  }
  if (path.endsWith('/vouchers')) {
    return {'current_page': 1, 'pages': 1, 'per_page': 20, 'total': 3, 'cancelled_hidden': {},
            'available_creators': [], 'available_parties': [], 'current_summary': {},
            'vouchers': [for (var i = 1; i <= 3; i++) _voucher(i)]};
  }
  if (path.endsWith('/journal_entries')) {
    return {'current_page': 1, 'pages': 1, 'per_page': 25, 'total': 3, 'cancelled_hidden': {},
            'available_creators': [], 'available_entry_types': [], 'current_summary': {},
            'journal_entries': [for (var i = 1; i <= 3; i++) _entry(i)]};
  }
  if (path.endsWith('/accounts')) return [];
  if (path.contains('customers') || path.contains('suppliers') || path.contains('items')) return [];
  return {};
}

Map<String, dynamic> _line(int id, String day, String what, double debit, double credit, double running) => {
      'id': id, 'date': '${day}T10:00:00', 'description': what, 'journal_entry_id': id, 'entry_number': 'JE-$id',
      'cash_debit': debit, 'cash_credit': credit, 'gold_debit': 0.0, 'gold_credit': 0.0,
      'running_cash_balance': running, 'running_gold_balance': 0.0,
    };

class _StatementApi extends ApiService {
  @override
  Future<Map<String, dynamic>> getCustomerStatement(int customerId, {bool includeCancelled = false}) async => {
        'opening_balance_cash': 0.0, 'opening_balance_gold_normalized': 0.0,
        'closing_balance_cash': 1200.0, 'closing_balance_gold_normalized': 0.0, 'main_karat': 21,
        'totals': {'cash_debit': 5200.0, 'cash_credit': 4000.0, 'gold_debit_normalized': 0.0, 'gold_credit_normalized': 0.0},
        'lines': [
          _line(1, '2026-11-01', 'فاتورة بيع بوصف طويل يحتاج أكثر من سطر على الهاتف', 5200, 0, 5200),
          _line(2, '2026-11-05', 'سند قبض', 0, 4000, 1200),
        ],
      };
}

Future<List<String>> _open(WidgetTester tester, Size size, Widget screen) async {
  // Signed in, with the lists' permissions: without them a list draws its
  // refusal, not its rows (the first run of this test passed on that).
  SharedPreferences.setMockInitialValues({
    'jwt_token': 'token',
    'auth_current_user': jsonEncode(AppUserModel.fromJson({
      'id': 3, 'username': 'manager', 'full_name': 'مدير تجريبي', 'role': 'manager', 'is_active': true,
      'is_admin': false, 'employee_id': 15, 'permissions': null, 'must_change_password': false,
      'effective_permissions': const [
        'invoices.view', 'invoices.view_others', 'vouchers.view', 'journal.view', 'accounts.view',
        'customers.view', 'suppliers.view', 'reports.financial',
      ],
    }).toStorageMap()),
    'app_settings': jsonEncode({'main_karat': 21}),
  });
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final settings = SettingsProvider();
  await settings.loadSettings(fetchRemote: false);
  final auth = AuthProvider();
  await auth.init();
  final found = <String>[];
  final before = FlutterError.onError;
  FlutterError.onError = (details) => found.add(details.exceptionAsString().split('\n').first);
  try {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(MultiProvider(
          providers: [
            ChangeNotifierProvider<AuthProvider>.value(value: auth),
            ChangeNotifierProvider.value(value: settings),
          ],
          child: MaterialApp(
            theme: LightTheme.theme,
            home: Directionality(textDirection: TextDirection.rtl, child: screen),
          ),
        ));
        for (var i = 0; i < 15; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
      },
      () => MockClient((request) async => http.Response.bytes(
            utf8.encode(jsonEncode(_answer(request.url.path))),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          )),
    );
  } finally {
    FlutterError.onError = before;
  }
  return found;
}

// What each list's first row says: proof its rows were drawn.
const _firstRow = {
  'الفواتير': 'SELL-2026-00001',
  'السندات': 'RV-2026-00001',
  'القيود': 'JE-2026-00001',
  'كشف الحساب': 'سند قبض',
};

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

  final screens = <String, Widget Function()>{
    'الفواتير': () => const InvoicesListScreen(),
    'السندات': () => const VouchersListScreen(),
    'القيود': () => const JournalEntriesListScreen(),
    'كشف الحساب': () => AccountStatementScreen(
          accountId: 7, accountName: 'عميل تجريبي', entityType: 'customer', apiService: _StatementApi()),
  };

  for (final MapEntry(key: name, value: make) in screens.entries) {
    for (final MapEntry(key: device, value: size) in _sizes.entries) {
      final phone = size.width < 600;
      testWidgets('$name على $device: ${phone ? 'بطاقات' : 'جدول'}، ولا يفيض شيء', (tester) async {
        final errors = await _open(tester, size, make());
        expect(errors, isEmpty, reason: '$name على $device: nothing overflows, nothing fails to draw');
        expect(find.byIcon(Icons.table_rows_outlined), phone ? findsWidgets : findsNothing,
            reason: phone ? 'a phone draws cards (the toggle offers the table)' : 'a tablet keeps the table');
        expect(find.textContaining(_firstRow[name]!), findsWidgets, reason: 'its rows are drawn, not a refusal');
      });
    }
  }

  testWidgets('the toggle still changes it on a phone', (tester) async {
    await _open(tester, _sizes['iPhone']!, const VouchersListScreen());
    expect(find.byIcon(Icons.table_rows_outlined), findsOneWidget);
    await tester.tap(find.byIcon(Icons.table_rows_outlined));
    await tester.pump();
    expect(find.byIcon(Icons.table_rows_outlined), findsNothing, reason: 'the table, as chosen');
  });
}
