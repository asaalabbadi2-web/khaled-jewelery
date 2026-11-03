// REPORTS ت2-1 (ADR-083): the balance sheet on the reports' shell. The
// journey: it opens on today; its sections, their totals and a line said
// apart (riyals on a weight account) are drawn as such; its checks are said;
// a group opens the trial balance of its accounts to the sheet's day.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/reports/balance_sheet_report_screen.dart';
import 'package:frontend/screens/reports/trial_balance_report_screen.dart';
import 'package:frontend/theme/app_theme.dart';

class _Server extends ApiService {
  final days = <String>[];
  final trial = <({String? end, int? under})>[];

  @override
  Future<Map<String, dynamic>> getBalanceSheet({required String asOf}) async {
    days.add(asOf);
    Map<String, dynamic> line(
      String name,
      num? cash,
      num? weight, {
      String? style,
      int? id,
    }) => {
      'name': name,
      'number': id == null ? null : '$id',
      'cash': cash,
      'weight': weight,
      'style': style,
      'drill': id == null ? null : {'kind': 'account', 'id': id},
    };
    return {
      'id': 'balance_sheet',
      'title': 'الميزانية العمومية',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': asOf},
      'columns': [
        {'key': 'number', 'label': 'الحساب', 'kind': 'text'},
        {'key': 'name', 'label': 'البند', 'kind': 'text'},
        {'key': 'cash', 'label': 'ريال', 'kind': 'money', 'signed': true},
        {'key': 'weight', 'label': 'جم', 'kind': 'grams', 'signed': true},
      ],
      'rows': [
        line('الأصول', null, null, style: 'heading'),
        line('المخزون', 5400918.67, 22432.17, id: 130),
        line(
          'ريالات مقيّدة على حسابات وزنية',
          634899.15,
          null,
          style: 'finding',
        ),
        line('مجموع الأصول', 6676245.02, 42509.255, style: 'subtotal'),
        line(
          'ربح الجرام للسنة حتى تاريخه (الطبقات الخمس) — لا يدخل المجموع',
          null,
          2884.573,
          style: 'note',
        ),
      ],
      'totals': <String, dynamic>{},
      'checks': [
        {
          'key': 'balanced_cash',
          'label': 'الأصول = الخصوم + حقوق الملكية (ريال)',
          'ok': true,
        },
        {
          'key': 'no_riyals_on_weight',
          'label': 'لا ريالات على الحسابات الوزنية',
          'ok': false,
        },
      ],
      'read_at': '2026-11-04T10:32:00',
    };
  }

  @override
  Future<Map<String, dynamic>> getTrialBalance({
    String? startDate,
    String? endDate,
    bool karatDetail = false,
    int? under,
  }) async {
    trial.add((end: endDate, under: under));
    return {
      'id': 'trial_balance',
      'title': 'ميزان المراجعة',
      'basis': 'posted_entries',
      'period': {'start': null, 'end': endDate},
      'columns': [
        {'key': 'account_name', 'label': 'الحساب', 'kind': 'text'},
      ],
      'rows': [
        {'account_name': 'مخزون الذهب ـ معروض للبيع'},
      ],
      'totals': <String, dynamic>{},
      'checks': [],
      'read_at': '2026-11-04T10:32:00',
    };
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('it opens on today; sections, totals and a finding drawn; '
      'a group opens its accounts to that day', (tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: BalanceSheetReportScreen(
            api: server,
            now: () => DateTime(2026, 10, 31, 17),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(server.days, ['2026-10-31']);
    expect(find.byKey(const ValueKey('report-day')), findsOneWidget);
    expect(find.text('مجموع الأصول'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('report-check-no_riyals_on_weight')),
      findsOneWidget,
    );
    final note = tester.widget<Text>(find.text('2,884.573'));
    expect(
      note.style?.fontStyle,
      FontStyle.italic,
      reason: 'a note, not summed',
    );
    final finding = tester.widget<Text>(
      find.text('ريالات مقيّدة على حسابات وزنية'),
    );
    expect(finding.data, isNotEmpty);

    await tester.tap(find.text('المخزون'));
    await _settle(tester);
    final trial = tester.widget<TrialBalanceReportScreen>(
      find.byType(TrialBalanceReportScreen),
    );
    expect((trial.under, trial.title), (130, 'المخزون'));
    expect(server.trial.single, (end: '2026-10-31', under: 130));
  });
}
