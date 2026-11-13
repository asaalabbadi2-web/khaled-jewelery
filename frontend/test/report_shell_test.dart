// REPORTS ت1-1 (ADR-083): one screen for any report, the trial balance on it
// first. The journey: it opens on all periods; a ready period sends its days;
// the karat switch reads again karat by karat; the checks, the totals and
// where the figures come from are said; a row opens its account's statement;
// Excel, PDF and print give what the screen shows; an error retries; nothing
// in a period offers all periods; a figure stands under its title.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/report_contract.dart';
import 'package:frontend/screens/account_statement_screen.dart';
import 'package:frontend/screens/reports/trial_balance_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/report_export.dart';

class _Server extends ApiService {
  final asked = <({String? start, String? end, bool karat})>[];
  bool fail = false;
  bool empty = false;

  Map<String, dynamic> _report(bool karat) => {
    'id': 'trial_balance',
    'title': 'ميزان المراجعة',
    'basis': 'posted_entries',
    'period': {'start': null, 'end': null},
    'columns': [
      {'key': 'account_number', 'label': 'رقم الحساب', 'kind': 'text'},
      {'key': 'account_name', 'label': 'الحساب', 'kind': 'text'},
      {'key': 'cash_debit', 'label': 'مدين نقد', 'kind': 'money'},
      {'key': 'cash_credit', 'label': 'دائن نقد', 'kind': 'money'},
      {
        'key': 'cash_balance',
        'label': 'الرصيد نقد',
        'kind': 'money',
        'signed': true,
      },
      if (karat) ...[
        {'key': 'debit_21k', 'label': 'مدين 21', 'kind': 'grams'},
        {'key': 'credit_21k', 'label': 'دائن 21', 'kind': 'grams'},
      ] else ...[
        {'key': 'gold_debit', 'label': 'مدين وزن', 'kind': 'grams'},
        {'key': 'gold_credit', 'label': 'دائن وزن', 'kind': 'grams'},
      ],
    ],
    'rows': empty
        ? []
        : [
            {
              'account_id': 110,
              'account_number': '1100',
              'account_name': 'النقدية',
              'cash_debit': 426580.59,
              'cash_credit': 0.0,
              'cash_balance': 426580.59,
              'gold_debit': 0.0,
              'gold_credit': 112.297,
              'debit_21k': 0.0,
              'credit_21k': 112.297,
              'drill': {'kind': 'account', 'id': 110},
            },
            {
              'account_id': 21,
              'account_number': '21',
              'account_name': 'الموردون',
              'cash_debit': 0.0,
              'cash_credit': 426580.59,
              'cash_balance': -426580.59,
              'gold_debit': 112.297,
              'gold_credit': 0.0,
              'debit_21k': 112.297,
              'credit_21k': 0.0,
              'drill': {'kind': 'account', 'id': 21},
            },
          ],
    'totals': {
      'cash_debit': 426580.59,
      'cash_credit': 426580.59,
      'cash_balance': 0.0,
      'gold_debit': 112.297,
      'gold_credit': 112.297,
      'debit_21k': 112.297,
      'credit_21k': 112.297,
    },
    'checks': [
      {
        'key': 'cash_balanced',
        'label': 'مجموع المدين = مجموع الدائن (نقد)',
        'ok': true,
      },
      {
        'key': 'gold_balanced',
        'label': 'مجموع المدين = مجموع الدائن (وزن)',
        'ok': true,
      },
    ],
    'read_at': '2041-05-20T10:32:00',
  };

  @override
  Future<Map<String, dynamic>> getTrialBalance({
    String? startDate,
    String? endDate,
    bool karatDetail = false,
    int? under,
  }) async {
    asked.add((start: startDate, end: endDate, karat: karatDetail));
    if (fail) throw Exception('الخادم لم يردّ');
    return _report(karatDetail);
  }

  @override
  Future<Map<String, dynamic>> getAccountById(int id) async => {
    'id': id,
    'name': 'النقدية',
    'account_number': '1100',
  };
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

final saved = <(String, List<int>, String)>[];
var printed = <int>[];

Future<_Server> _open(WidgetTester tester, {_Server? server, Size size = const Size(1400, 1000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final s = server ?? _Server();
  await tester.pumpWidget(
    MaterialApp(
      theme: LightTheme.theme,
      home: Directionality(
        textDirection: TextDirection.rtl,
        child: TrialBalanceReportScreen(
          api: s,
          now: () => DateTime(2041, 5, 20),
          saver: (name, bytes, mime) async => saved.add((name, bytes, mime)),
          printer: (pdf) async => printed = await pdf(),
        ),
      ),
    ),
  );
  await _settle(tester);
  return s;
}

void main() {
  // On a phone each line is a card (the owner, 13 Nov 2026): its description
  // its title, each figure under it by its column's name; the totals the last
  // card; a card opens what its row opens. An iPad keeps the table.
  for (final (device, size) in [('iPhone SE', const Size(375, 667)), ('iPhone', const Size(390, 844))]) {
    testWidgets('on an $device each line is a card, and nothing overflows', (tester) async {
      final errors = <String>[];
      final before = FlutterError.onError;
      FlutterError.onError = (d) => errors.add(d.exceptionAsString().split('\n').first);
      try {
        await _open(tester, size: size);
      } finally {
        FlutterError.onError = before;
      }
      expect(errors, isEmpty);
      expect(find.byKey(const ValueKey('report-head-cash_debit')), findsNothing, reason: 'no table');
      expect(find.descendant(of: find.byKey(const ValueKey('report-row-1')), matching: find.text('الموردون')),
          findsOneWidget, reason: 'its description its title');
      expect(find.descendant(of: find.byKey(const ValueKey('report-row-1')), matching: find.text('مدين نقد')),
          findsNothing, reason: 'a zero is not said -- noise on a phone');
      expect(find.descendant(of: find.byKey(const ValueKey('report-row-1')), matching: find.text('دائن نقد')),
          findsOneWidget, reason: 'each figure by its column\'s name');
      final negative = tester.widget<Text>(find.text('\u200e-426,580.59'));
      expect(negative.style?.color, Theme.of(tester.element(find.text('\u200e-426,580.59'))).colorScheme.error);
      expect(find.byKey(const ValueKey('report-totals')), findsOneWidget);
    });
  }

  testWidgets('on a phone a card opens its row\'s account statement', (tester) async {
    await _open(tester, size: const Size(390, 844));
    await tester.tap(find.byKey(const ValueKey('report-row-0')));
    await _settle(tester);
    expect(tester.widget<AccountStatementScreen>(find.byType(AccountStatementScreen)).accountId, 110);
  });

  testWidgets('an iPad keeps the table', (tester) async {
    await _open(tester, size: const Size(744, 1133));
    expect(find.byKey(const ValueKey('report-head-cash_debit')), findsOneWidget);
  });

  testWidgets('it opens on all periods, its checks, totals and source said', (
    tester,
  ) async {
    final server = await _open(tester);
    expect(server.asked.single, (start: null, end: null, karat: false));
    expect(find.text('الموردون'), findsOneWidget);
    expect(find.byKey(const ValueKey('report-totals')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('report-check-cash_balanced')),
      findsOneWidget,
    );
    final source = tester
        .widget<Text>(find.byKey(const ValueKey('report-source')))
        .data!;
    expect(source, allOf(contains('من القيود المرحّلة'), contains('10:32')));
  });

  testWidgets('a ready period sends its days; the karat switch reads again', (
    tester,
  ) async {
    final server = await _open(tester);
    await tester.tap(find.byKey(const ValueKey('report-period')));
    await _settle(tester);
    await tester.tap(find.text('هذا الشهر').last);
    await _settle(tester);
    expect(server.asked.last, (
      start: '2041-05-01',
      end: '2041-05-20',
      karat: false,
    ));
    await tester.tap(find.byKey(const ValueKey('report-toggle-karat_detail')));
    await _settle(tester);
    expect(server.asked.last.karat, isTrue);
    expect(find.byKey(const ValueKey('report-head-debit_21k')), findsOneWidget);
  });

  testWidgets('a row opens its account\'s statement', (tester) async {
    await _open(tester);
    await tester.tap(find.text('النقدية').first);
    await _settle(tester);
    final screen = tester.widget<AccountStatementScreen>(
      find.byType(AccountStatementScreen),
    );
    expect(screen.accountId, 110);
  });

  testWidgets('a negative balance is said in the error tone', (tester) async {
    await _open(tester);
    // a negative carries its left-to-right mark (formatAmount)
    final negative = tester.widget<Text>(find.text('\u200e-426,580.59'));
    final theme = Theme.of(tester.element(find.text('\u200e-426,580.59')));
    expect(negative.style?.color, theme.colorScheme.error);
  });

  testWidgets('a figure stands under its title, at the column\'s right edge', (
    tester,
  ) async {
    await _open(tester);
    final head = tester.getTopRight(
      find.byKey(const ValueKey('report-head-cash_debit')),
    );
    final figure = tester.getTopRight(find.text('426,580.59').first);
    expect(figure.dx, closeTo(head.dx, 0.5));
  });

  testWidgets('an error is retried; nothing in a period offers all periods', (
    tester,
  ) async {
    final server = _Server()..fail = true;
    await _open(tester, server: server);
    expect(find.text('إعادة المحاولة'), findsOneWidget);
    server
      ..fail = false
      ..empty = true;
    await tester.tap(find.text('إعادة المحاولة'));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('report-period')));
    await _settle(tester);
    await tester.tap(find.text('هذا الشهر').last);
    await _settle(tester);
    expect(find.text('لا قيود مرحّلة في هذه الفترة'), findsOneWidget);
    await tester.tap(find.text('كل الفترات').last);
    await _settle(tester);
    expect(server.asked.last.start, isNull);
  });

  test('Excel holds the screen\'s columns, rows and totals', () {
    final report = ReportData.fromJson(_Server()._report(false));
    final bytes = reportXlsx(report);
    expect(bytes.take(2), [0x50, 0x4B], reason: 'an xlsx is a zip');
    expect(reportFileName(report, 'xlsx'), 'trial_balance.xlsx');
    expect(reportCell(report.columns[2], 426580.59), '426,580.59');
    expect(reportCell(report.columns[5], 112.297), '112.297');
  });

  testWidgets('Excel, PDF and print give what the screen shows', (
    tester,
  ) async {
    saved.clear();
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('report-excel')));
    await _settle(tester);
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const ValueKey('report-pdf')));
      await Future<void>.delayed(const Duration(seconds: 2));
      await tester.tap(find.byKey(const ValueKey('report-print')));
      await Future<void>.delayed(const Duration(seconds: 2));
    });
    await _settle(tester);
    expect(saved.map((s) => s.$1), ['trial_balance.xlsx', 'trial_balance.pdf']);
    expect(saved.first.$2.take(2), [0x50, 0x4B]);
    expect(String.fromCharCodes(saved.last.$2.take(4)), '%PDF');
    expect(String.fromCharCodes(printed.take(4)), '%PDF');
  });
}
