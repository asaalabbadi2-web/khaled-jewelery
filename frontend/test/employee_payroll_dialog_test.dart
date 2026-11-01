import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/payroll_run_models.dart';
import 'package:frontend/screens/payroll_runs_screen.dart';
import 'package:frontend/services/payroll_service.dart';
import 'package:frontend/theme/app_theme.dart';

/// HR-UX ط1 (the owner, 2 Nov 2026, «اعتمد»): a new structure is offered from
/// the server's day -- the first of this month left him out of October's run,
/// not yet drafted; what was typed and not saved is said before the dialog
/// closes; a structure is deleted when that is confirmed.
class _Server extends PayrollService {
  _Server() : super(ApiService());

  int? deleted;

  @override
  Future<(List<SalaryStructureModel>, String?)> structures(
    int employeeId,
  ) async => (
    [
      SalaryStructureModel.fromJson({
        'id': 4,
        'effective_from': '2026-09-01',
        'basic': 5185.19,
        'housing': 1296.30,
        'transport': 518.51,
        'other_allowances': 0.0,
        'gross': 7000.0,
      }),
    ],
    '2026-10-01',
  );

  @override
  Future<Map<String, dynamic>> payment(int employeeId) async => {
    'payment_method': 'bank',
    'iban': null,
    'bank_name': null,
    'contribution_scheme_id': null,
    'contribution_wage': null,
  };

  @override
  Future<List<Map<String, dynamic>>> schemes() async => const [];

  @override
  Future<(List<AdvancePlanModel>, double, double)> advancePlans(
    int employeeId,
  ) async => (<AdvancePlanModel>[], 0.0, 0.0);

  @override
  Future<void> deleteStructure(int structureId) async => deleted = structureId;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('offered from the server\'s day; the unsaved said; the delete '
      'confirmed', (tester) async {
    tester.view.physicalSize = const Size(900, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final server = _Server();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              key: const ValueKey('open'),
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => EmployeePayrollDialog(
                  service: server,
                  employeeId: 7,
                  name: 'مسعد',
                  isAr: true,
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await _settle(tester);

    final from = tester.widget<TextField>(
      find.descendant(
        of: find.byKey(const ValueKey('structure-from')),
        matching: find.byType(TextField),
      ),
    );
    expect(from.controller!.text, '2026-10-01', reason: 'the server\'s day');

    await tester.tap(find.byKey(const ValueKey('structure-delete-4')));
    await _settle(tester);
    expect(server.deleted, isNull, reason: 'not before it is confirmed');
    await tester.tap(find.byKey(const ValueKey('structure-delete-confirm')));
    await _settle(tester);
    expect(server.deleted, 4);

    await tester.enterText(
      find.byKey(const ValueKey('employee-iban')),
      'SA0380000000608010167519',
    );
    await tester.tap(find.byKey(const ValueKey('employee-payroll-close')));
    await _settle(tester);
    expect(find.textContaining('الصرف والاشتراك'), findsWidgets);
    expect(
      find.byKey(const ValueKey('employee-payroll-leave')),
      findsOneWidget,
    );
    await tester.tap(find.text('رجوع'));
    await _settle(tester);
    expect(
      find.byKey(const ValueKey('employee-iban')),
      findsOneWidget,
      reason: 'back: the IBAN is still there to save',
    );
    await tester.tap(find.byKey(const ValueKey('employee-payroll-close')));
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('employee-payroll-leave')));
    await _settle(tester);
    expect(find.byKey(const ValueKey('employee-iban')), findsNothing);
  });
}
