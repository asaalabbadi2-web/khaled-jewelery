import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/payroll_runs_screen.dart';
import 'package:frontend/screens/prepare_run_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/record_card.dart';

/// HR-UX ط4 (the owner, 2 Nov 2026, «اعتمد»): the month by its name, the first
/// without a run offered; its run seen before it is made -- who is in, who is
/// left out and why, who would stop the pay --; then its draft.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  final previewed = <int>[];
  (int, int)? drafted;

  Map<String, dynamic> _line(int id, String name, String? method, double net) =>
      {
        'id': id,
        'employee_id': id * 10,
        'basic_salary': net,
        'allowances': 0.0,
        'deductions': 0.0,
        'net_salary': net,
        'status': 'pending',
        'employee': {'name': name, 'payment_method': method},
        'breakdown': {
          'bonuses': <dynamic>[],
          'earned': {'basic': net},
        },
      };

  @override
  Future<(List<PayrollRunMonth>, ({int month, int year})?)> runMonths() async =>
      (
        [
          PayrollRunMonth.fromJson({
            'month': 9,
            'year': 2026,
            'state': 'entries',
          }),
          PayrollRunMonth.fromJson({
            'month': 10,
            'year': 2026,
            'state': 'open',
          }),
          PayrollRunMonth.fromJson({
            'month': 11,
            'year': 2026,
            'state': 'open',
            'current': true,
          }),
        ],
        (month: 10, year: 2026),
      );

  @override
  Future<PayrollRunPreview> previewRun({
    required int month,
    required int year,
  }) async {
    previewed.add(month);
    return PayrollRunPreview.fromJson({
      'id': null,
      'month': month,
      'year': year,
      'status': 'draft',
      'entries': [
        _line(1, 'مسعد', 'bank', 7000),
        _line(2, 'عبدالله', null, 8640),
      ],
      'left_out': [
        {'employee_id': 15, 'name': 'صالح', 'reason': 'no_structure'},
      ],
      'totals': {
        'basic_salary': 15640.0,
        'allowances': 0.0,
        'net_salary': 15640.0,
        'bonuses': 1140.0,
      },
      'will_not_pay': [
        {'employee_id': 20, 'name': 'عبدالله'},
      ],
    });
  }

  @override
  Future<PayrollRun> generate({required int month, required int year}) async {
    drafted = (month, year);
    return PayrollRun.fromJson({
      'id': 9,
      'month': month,
      'year': year,
      'status': 'draft',
    });
  }

  @override
  Future<PayrollRun> getRun(int id) async => PayrollRun.fromJson({
    'id': id,
    'month': 10,
    'year': 2026,
    'status': 'draft',
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets(
    'October offered by its name, seen before it is made, then drafted',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server();
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PrepareRunScreen(api: ApiService(), service: server),
        ),
      );
      await _settle(tester);
      expect(server.previewed, [
        10,
      ], reason: 'the first without a run, not this November');
      expect(find.text('أول شهر بلا مسير'), findsOneWidget);
      expect(find.text('سجلات قبل المسيرات'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('prepare-out-15')),
        findsOneWidget,
        reason: 'left out, and why',
      );
      expect(find.textContaining('لا هيكل راتب له'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('prepare-wont-pay-20')),
        findsOneWidget,
        reason: 'would stop the pay',
      );
      expect(find.byKey(const ValueKey('prepare-fix-15')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('prepare-lines')),
          matching: find.text('مسعد'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('15,640.00'), findsWidgets);

      await tester.tap(find.byKey(const ValueKey('prepare-month-2026-11')));
      await _settle(tester);
      expect(server.previewed, [10, 11]);
      await tester.tap(find.byKey(const ValueKey('prepare-month-2026-9')));
      await _settle(tester);
      expect(server.previewed, [
        10,
        11,
      ], reason: 'a month written before the runs is not drafted');
      await tester.tap(find.byKey(const ValueKey('prepare-month-2026-10')));
      await _settle(tester);

      expect(find.text('أنشئ مسودة أكتوبر'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('prepare-draft')));
      await _settle(tester);
      expect(server.drafted, (10, 2026));
      expect(find.byType(PayrollRunScreen), findsOneWidget);
    },
  );

  testWidgets('at a phone\'s width nothing overflows', (tester) async {
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: PrepareRunScreen(api: ApiService(), service: _Server()),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    // each employee a card, not a table slid sideways (the owner, 13 Nov 2026)
    expect(find.byType(DataTable), findsNothing);
    expect(
      find.descendant(of: find.byKey(const ValueKey('prepare-lines')), matching: find.byType(RecordCard)),
      findsWidgets,
    );
    expect(
      find.descendant(of: find.byKey(const ValueKey('prepare-line-20')), matching: find.text('لا طريقة صرف')),
      findsOneWidget,
      reason: 'who would stop the pay is said on his card',
    );
  });

  testWidgets('in Arabic each figure stands under its column\'s title', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        builder: (context, child) =>
            Directionality(textDirection: TextDirection.rtl, child: child!),
        home: PrepareRunScreen(api: ApiService(), service: _Server()),
      ),
    );
    await _settle(tester);
    double inkRight(Finder f) {
      final paragraph = tester.renderObject<RenderParagraph>(
        find
            .descendant(of: f, matching: find.byType(RichText), matchRoot: true)
            .first,
      );
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      );
      return paragraph
          .localToGlobal(
            Offset(
              boxes.map((b) => b.right).reduce((a, b) => a > b ? a : b),
              0,
            ),
          )
          .dx;
    }

    final lines = find.byKey(const ValueKey('prepare-lines'));
    final head = inkRight(
      find.descendant(of: lines, matching: find.text('الصافي')),
    );
    for (final net in ['7,000.00', '8,640.00']) {
      // the net is its row's last figure (its salary may read the same)
      final cell = inkRight(
        find.descendant(of: lines, matching: find.textContaining(net)).last,
      );
      expect((cell - head).abs(), lessThan(1), reason: net);
    }
  });
}
