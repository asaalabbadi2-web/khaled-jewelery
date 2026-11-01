import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/models/employee_model.dart';
import 'package:frontend/models/safe_box_model.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/widgets/employee_data_panel.dart';

/// HR-UX ط3 (the owner, 2 Nov 2026, «اعتمد»): his data edited where it is
/// shown, one section at a time, each saved alone; a hire date emptied is
/// cleared (the earlier dialog dropped it); what another document owns says
/// where it is.
class _Api extends ApiService {
  Map<String, dynamic>? sent;

  @override
  Future<List<SafeBoxModel>> getSafeBoxes({
    String? safeType,
    bool? isActive,
    int? karat,
    bool includeAccount = false,
    bool includeBalance = false,
  }) async => const [];

  @override
  Future<EmployeeModel> updateEmployee(
    int employeeId,
    Map<String, dynamic> payload,
  ) async {
    sent = payload;
    return EmployeeModel.fromJson({'id': employeeId, 'name': 'مسعد المهري'});
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('one section opened, saved alone; the hire date cleared', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1100, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    String? went;
    final unsaved = ValueNotifier<List<String>>(const []);
    addTearDown(unsaved.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeeDataPanel(
              api: api,
              isAr: true,
              unsaved: unsaved,
              onGo: (part) => went = part,
              employee: const {
                'id': 16,
                'name': 'مسعد المهري',
                'job_title': 'بائع',
                'hire_date': '2025-03-15',
                'national_id': null,
              },
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('data-add-national_id')), findsOneWidget);
    expect(find.text('الراتب الأساسي'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('data-edit-work')));
    await _settle(tester);
    FilledButton save() =>
        tester.widget<FilledButton>(find.byKey(const ValueKey('data-save')));
    expect(save().onPressed, isNull, reason: 'nothing changed yet');
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('data-field-hire_date')),
        matching: find.byType(TextField),
      ),
      '',
    );
    await _settle(tester);
    expect(unsaved.value, isNotEmpty, reason: 'told to the page');
    await tester.tap(find.byKey(const ValueKey('data-save')));
    await _settle(tester);
    expect(api.sent, {
      'job_title': 'بائع',
      'department': null,
      'hire_date': null,
    }, reason: 'its section alone; the date sent empty, so cleared');

    await tester.tap(find.byKey(const ValueKey('data-go-salary')));
    expect(went, 'salary');
  });

  testWidgets('the name is required; a phone\'s width holds', (tester) async {
    tester.view.physicalSize = const Size(390, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EmployeeDataPanel(
              api: api,
              isAr: true,
              employee: const {'id': 16, 'name': 'مسعد المهري'},
            ),
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('data-edit-personal')));
    await _settle(tester);
    await tester.enterText(find.byKey(const ValueKey('data-field-name')), '');
    await _settle(tester);
    await tester.tap(find.byKey(const ValueKey('data-save')));
    await _settle(tester);
    expect(find.text('الاسم مطلوب'), findsOneWidget);
    expect(api.sent, isNull);
    expect(tester.takeException(), isNull);
  });
}
