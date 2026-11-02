import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/payroll_runs_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// PAYROLL-2 (the owner, 1 Nov 2026, «اودع وابدأ»): a month's payroll is one
/// document -- the draft says who is left out and why, a line takes its
/// additions and deductions with their reasons, the run is approved whole,
/// then paid in a batch by how each employee is paid; nothing is paid while
/// one line has no account to leave from.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  String status = 'draft';
  List<Map<String, dynamic>> deductions = [];

  /// What the batch pay was sent: each line's (bank, cash), and the accounts.
  Map<int, ({double bank, double cash})>? paidWith;
  Map<int, ({int karat, double grams})>? goldWith;

  /// PAY-GOLD: مسعد owes 10 g of 21k, a gram at 400 today (the server's).
  bool goldOwed = false;
  (int?, int?)? paidFrom;
  int? added;

  Map<String, dynamic> _line(
    int id,
    String name,
    String? method,
    double net,
  ) => {
    'id': id,
    'employee_id': id * 10,
    'basic_salary': net,
    'allowances': 0.0,
    'deductions': 0.0,
    'net_salary': net,
    'status': switch (status) {
      'draft' => 'pending',
      'approved' => 'approved',
      _ => 'paid',
    },
    'employee': {'name': name, 'payment_method': method},
    // the server's offer (PAY-SPLIT): his way, whole; none said, none offered
    if (status == 'approved')
      'offered': method == null
          ? <String, dynamic>{}
          : <String, dynamic>{method: net},
    if (status == 'paid') 'voucher': {'voucher_number': 'PAY-2041-04-000$id'},
    if (goldOwed && id == 1 && status == 'approved') ...{
      'gold_advance': {'21k': 10.0},
      'gold_rates': {'21k': 400.0},
    },
    'breakdown': {
      'eos': id == 1
          ? {'days': 400, 'provision': 350.0}
          : {'reason': 'no_hire_date', 'provision': 0.0},
      'days': 30,
      'whole_month': true,
      'earned': {'basic': net},
      'additions': <dynamic>[],
      'deductions': id == 1
          ? [
              {'kind': 'contribution', 'label': 'المعاشات', 'amount': 360.0},
              ...deductions,
            ]
          : <dynamic>[],
      'bonuses': id == 2
          ? [
              {'bonus_id': 55, 'label': 'هدف الشهر', 'amount': 500.0},
            ]
          : <dynamic>[],
      if (id == 2)
        'bonus_books_cap': {'approved_unpaid': 2912.5, 'owed_in_books': 500.0},
      if (id == 1)
        'bonuses_held': {'approved_unpaid': 2512.5, 'owed_in_books': 0.0},
      'employer_contributions': id == 1
          ? [
              {'code': 'annuities', 'name': 'المعاشات', 'amount': 440.0},
            ]
          : <dynamic>[],
    },
  };

  PayrollRun get _run {
    final cut = deductions.fold<double>(0, (s, d) => s + (d['amount'] as num));
    return PayrollRun.fromJson({
      'id': 9,
      'month': 4,
      'year': 2041,
      'status': status,
      'entries': [
        _line(1, 'مسعد', 'bank', 7000 - cut),
        _line(2, 'مبارك', null, 7500),
      ],
      'left_out': [
        {'employee_id': 30, 'name': 'يوسف', 'reason': 'no_structure'},
      ],
      'totals': {'net_salary': 14500 - cut},
    });
  }

  @override
  Future<PayrollRun> getRun(int id) async => _run;

  @override
  Future<PayrollRun> editLine(
    int runId,
    int lineId, {
    required List<PayrollLabelledAmount> additions,
    required List<PayrollLabelledAmount> deductions,
    List<int>? keptBonuses,
    String? notes,
  }) async {
    this.deductions = deductions.map((d) => d.toJson()).toList();
    return _run;
  }

  @override
  Future<PayrollRun> addLine(int runId, int employeeId) async {
    added = employeeId;
    return _run;
  }

  @override
  Future<PayrollRun> approve(int runId) async {
    status = 'approved';
    return _run;
  }

  @override
  Future<List<Map<String, dynamic>>> paymentAccounts() async => [
    {'id': 1, 'name': 'بنك الرياض'},
    {'id': 2, 'name': 'الصندوق'},
  ];

  @override
  Future<PayrollRun> pay(
    int runId, {
    required int? bankAccountId,
    required int? cashAccountId,
    required Map<int, ({double bank, double cash})> amountsByLine,
    Map<int, ({int karat, double grams})> goldByLine = const {},
    required String paidDate,
  }) async {
    paidWith = amountsByLine;
    goldWith = goldByLine;
    paidFrom = (bankAccountId, cashAccountId);
    status = 'paid';
    return _run;
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _choose(WidgetTester tester, String key, String item) async {
  await tester.tap(find.byKey(ValueKey(key)));
  await _settle(tester);
  await tester.tap(find.text(item).last);
  await _settle(tester);
}

void main() {
  testWidgets(
    'a run is reviewed, approved whole, then paid by how each is paid',
    (tester) async {
      tester.view.physicalSize = const Size(
        800,
        2000,
      ); // cards: a narrow screen's
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server();
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollRunScreen(api: ApiService(), runId: 9, service: server),
        ),
      );
      await _settle(tester);

      // the draft: its lines, and who is left out, with why
      expect(find.byKey(const ValueKey('payroll-line-10')), findsOneWidget);
      expect(find.textContaining('لا هيكل راتب له'), findsOneWidget);

      // HR-UX ط1: one put right is added to the draft, not drafted again
      await tester.tap(find.byKey(const ValueKey('payroll-left-out-add-30')));
      await _settle(tester);
      expect(server.added, 30);
      expect(
        find.byKey(const ValueKey('payroll-run-pay')),
        findsNothing,
        reason: 'a draft is approved first',
      );

      // a deduction, with its reason
      await tester.tap(find.byKey(const ValueKey('payroll-line-edit-10')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('deduction-add')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('deduction-label-0')),
        'غياب يوم',
      );
      await tester.enterText(
        find.byKey(const ValueKey('deduction-amount-0')),
        '٢٠٠',
      );
      await _choose(tester, 'deduction-kind-0', 'جزاء');
      await tester.tap(find.byKey(const ValueKey('payroll-line-save')));
      await _settle(tester);
      expect(
        server.deductions,
        [
          {'label': 'غياب يوم', 'amount': 200.0, 'kind': 'penalty'},
        ],
        reason: 'the reckoned contribution is not sent back as keyed',
      );
      expect(find.textContaining('(اشتراك)'), findsOneWidget);
      expect(find.textContaining('حصة المنشأة من الاشتراكات'), findsOneWidget);
      expect(find.textContaining('(مكافأة)'), findsOneWidget);
      expect(find.textContaining('لم تدخل: الدفاتر تقول'), findsOneWidget);
      expect(find.textContaining('تُصرف بما تقوله الدفاتر'), findsOneWidget);
      expect(find.textContaining('مخصص نهاية الخدمة للشهر'), findsOneWidget);
      expect(find.textContaining('لا تاريخ تعيين'), findsOneWidget);
      expect(find.textContaining('غياب يوم'), findsOneWidget);

      // approved whole
      await tester.tap(find.byKey(const ValueKey('payroll-run-approve')));
      await _settle(tester);
      expect(find.textContaining('قيد استحقاق واحد بصافي'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('payroll-run-confirm')));
      await _settle(tester);
      expect(server.status, 'approved');
      expect(
        find.byKey(const ValueKey('payroll-line-edit-10')),
        findsNothing,
        reason: 'approved is kept',
      );

      // paid: not while مبارك has no way to be paid
      await tester.tap(find.byKey(const ValueKey('payroll-run-pay')));
      await _settle(tester);
      await _choose(tester, 'payroll-pay-bank', 'بنك الرياض');
      FilledButton confirm() => tester.widget<FilledButton>(
        find.byKey(const ValueKey('payroll-pay-confirm')),
      );
      expect(confirm().onPressed, isNull, reason: 'none, not some');
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('payroll-pay-method-2')),
          matching: find.text('نقد'),
        ),
      );
      await _settle(tester);
      expect(confirm().onPressed, isNull, reason: 'cash, but from which safe');
      await _choose(tester, 'payroll-pay-cash', 'الصندوق');
      await tester.tap(find.byKey(const ValueKey('payroll-pay-confirm')));
      await _settle(tester);
      expect(server.paidWith, {
        1: (bank: 6800.0, cash: 0.0),
        2: (bank: 0.0, cash: 7500.0),
      });
      expect(server.paidFrom, (1, 2));
      expect(find.textContaining('PAY-2041-04-0001'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payroll-run-cancel')),
        findsNothing,
        reason: 'a paid run is not cancelled',
      );
    },
  );

  testWidgets(
    'on a wide screen: its stages, its totals, a table whose row opens its line',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollRunScreen(
            api: ApiService(),
            runId: 9,
            service: _Server(),
          ),
        ),
      );
      await _settle(tester);
      expect(find.byKey(const ValueKey('payroll-stage-1')), findsOneWidget);
      expect(
        find.textContaining('المراجعة'),
        findsOneWidget,
        reason: 'a draft is at its review',
      );
      expect(find.byKey(const ValueKey('payroll-run-totals')), findsOneWidget);
      expect(find.byKey(const ValueKey('payroll-lines-table')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('payroll-line-10')),
        findsNothing,
        reason: 'rows, not cards',
      );
      await tester.tap(find.text('مسعد'));
      await _settle(tester);
      expect(
        find.byKey(const ValueKey('payroll-line-10')),
        findsOneWidget,
        reason: 'its line in its sheet',
      );
      expect(
        find.byKey(const ValueKey('payroll-line-edit-10')),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'in Arabic, each figure stands under its column\'s title, its decimals '
    'aligned (the owner, 2 Nov 2026: «الأرقام ليست بمحاذاة عناوينها»)',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          builder: (context, child) =>
              Directionality(textDirection: TextDirection.rtl, child: child!),
          home: PayrollRunScreen(
            api: ApiService(),
            runId: 9,
            service: _Server(),
          ),
        ),
      );
      await _settle(tester);
      // where its letters are drawn -- not its box, which fills the column
      // whichever edge the text keeps to
      double inkRight(String key) {
        final paragraph = tester.renderObject<RenderParagraph>(
          find.descendant(
            of: find.byKey(ValueKey(key)),
            matching: find.byType(RichText),
            matchRoot: true,
          ),
        );
        final boxes = paragraph.getBoxesForSelection(
          TextSelection(
            baseOffset: 0,
            extentOffset: paragraph.text.toPlainText().length,
          ),
        );
        final right = boxes.map((b) => b.right).reduce((a, b) => a > b ? a : b);
        return paragraph.localToGlobal(Offset(right, 0)).dx;
      }

      for (final column in ['basic', 'allowances', 'net']) {
        final head = inkRight('payroll-head-$column');
        for (final employee in [10, 20]) {
          final cell = inkRight('payroll-cell-$employee-$column');
          expect(
            (cell - head).abs(),
            lessThan(1),
            reason: '$column of $employee: under its title, not beside it',
          );
        }
      }
    },
  );

  testWidgets(
    'an advance not planned is keyed in the draft, with his consent above '
    'the cap (the owner, 2 Nov 2026)',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server();
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollRunScreen(api: ApiService(), runId: 9, service: server),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('payroll-line-edit-10')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('deduction-add')));
      await _settle(tester);
      await tester.enterText(
        find.byKey(const ValueKey('deduction-label-0')),
        'سلفة نقدية',
      );
      await tester.enterText(
        find.byKey(const ValueKey('deduction-amount-0')),
        '2000',
      );
      await _choose(tester, 'deduction-kind-0', 'سلفة');
      await tester.tap(find.byKey(const ValueKey('deduction-consent-0')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('payroll-line-save')));
      await _settle(tester);
      expect(server.deductions, [
        {
          'label': 'سلفة نقدية',
          'amount': 2000.0,
          'kind': 'advance_keyed',
          'consent': true,
        },
      ]);
    },
  );

  testWidgets(
    'PAY-SPLIT: one paid part by bank part by cash, one keeps it all with the '
    'shop -- what is not paid said as kept owed to him',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server()..status = 'approved';
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollRunScreen(api: ApiService(), runId: 9, service: server),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('payroll-run-pay')));
      await _settle(tester);
      await _choose(tester, 'payroll-pay-bank', 'بنك الرياض');
      await _choose(tester, 'payroll-pay-cash', 'الصندوق');
      Future<void> mode(int id, String word) async {
        await tester.tap(
          find.descendant(
            of: find.byKey(ValueKey('payroll-pay-method-$id')),
            matching: find.text(word),
          ),
        );
        await _settle(tester);
      }

      await mode(1, 'مقسّم');
      await tester.enterText(
        find.byKey(const ValueKey('payroll-pay-bank-amount-1')),
        '5000',
      );
      await tester.enterText(
        find.byKey(const ValueKey('payroll-pay-cash-amount-1')),
        '1000',
      );
      await _settle(tester);
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('payroll-pay-kept-1')))
            .data,
        allOf(contains('يبقى في ذمته'), contains('1,000.00')),
      );
      await mode(2, 'يبقى');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('payroll-pay-kept-2')))
            .data,
        allOf(contains('يبقى في ذمته'), contains('7,500.00')),
      );
      await tester.tap(find.byKey(const ValueKey('payroll-pay-confirm')));
      await _settle(tester);
      expect(server.paidWith, {
        1: (bank: 5000.0, cash: 1000.0),
        2: (bank: 0.0, cash: 0.0),
      });
    },
  );

  testWidgets(
    'PAY-GOLD: his gold advance taken in riyals at the closing price -- what '
    'he is paid is his net less it, never more grams than he owes',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final server = _Server()
        ..status = 'approved'
        ..goldOwed = true;
      await tester.pumpWidget(
        MaterialApp(
          theme: LightTheme.theme,
          home: PayrollRunScreen(api: ApiService(), runId: 9, service: server),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('payroll-run-pay')));
      await _settle(tester);
      await _choose(tester, 'payroll-pay-bank', 'بنك الرياض');
      await _choose(tester, 'payroll-pay-cash', 'الصندوق');
      expect(
        find.byKey(const ValueKey('payroll-pay-gold-2')),
        findsNothing,
        reason: 'he owes no gold',
      );
      String said() => tester
          .widget<Text>(find.byKey(const ValueKey('payroll-pay-gold-said-1')))
          .data!;
      expect(said(), contains('10'), reason: 'what he owes, said');

      await tester.enterText(
        find.byKey(const ValueKey('payroll-pay-gold-1')),
        '11',
      );
      await _settle(tester);
      expect(said(), contains('يزيد على'));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('payroll-pay-confirm')),
            )
            .onPressed,
        isNull,
        reason: 'not more than he owes',
      );

      await tester.enterText(
        find.byKey(const ValueKey('payroll-pay-gold-1')),
        '4',
      );
      await _settle(tester);
      expect(said(), allOf(contains('1,600.00'), contains('سعر التسكير')));
      await tester.tap(
        find.descendant(
          of: find.byKey(const ValueKey('payroll-pay-method-2')),
          matching: find.text('نقد'),
        ),
      );
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('payroll-pay-confirm')));
      await _settle(tester);
      expect(server.paidWith?[1], (
        bank: 5400.0,
        cash: 0.0,
      ), reason: 'his net less the gold taken');
      expect(server.goldWith, {1: (karat: 21, grams: 4.0)});
    },
  );
}
