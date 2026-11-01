import 'dart:convert';

import 'package:http/http.dart' as http;

import '../api_service.dart';
import '../models/payroll_run_models.dart';

/// The payroll's runs, structures and policy (PAYROLL-2, ADR-068).
///
/// Every method throws [PayrollApiException] with the server's own reason on
/// a refusal -- the screen says it as it is.
class PayrollService {
  PayrollService(this._api);
  final ApiService _api;

  // ── runs ──────────────────────────────────────────────────────────────────

  Future<List<PayrollRunSummary>> listRuns() async {
    final resp = await _api.authedGet('/payroll/runs');
    return (_body(resp) as List)
        .map((e) => PayrollRunSummary.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<PayrollRun> getRun(int id) async =>
      _run(await _api.authedGet('/payroll/runs/$id'));

  Future<PayrollRun> generate({required int month, required int year}) async =>
      _run(
        await _api.authedPost(
          '/payroll/runs',
          body: jsonEncode({'month': month, 'year': year}),
        ),
      );

  Future<PayrollRun> editLine(
    int runId,
    int lineId, {
    required List<PayrollLabelledAmount> additions,
    required List<PayrollLabelledAmount> deductions,
    List<int>? keptBonuses,
    String? notes,
  }) async => _run(
    await _api.authedPut(
      '/payroll/runs/$runId/lines/$lineId',
      body: jsonEncode({
        'additions': additions.map((e) => e.toJson()).toList(),
        'deductions': deductions.map((e) => e.toJson()).toList(),
        'bonuses': ?keptBonuses,
        'notes': notes,
      }),
    ),
  );

  /// One put right since the draft was made, drafted into it (HR-UX ط1).
  Future<PayrollRun> addLine(int runId, int employeeId) async => _run(
    await _api.authedPost(
      '/payroll/runs/$runId/lines',
      body: jsonEncode({'employee_id': employeeId}),
    ),
  );

  Future<PayrollRun> removeLine(int runId, int lineId) async =>
      _run(await _api.authedDelete('/payroll/runs/$runId/lines/$lineId'));

  Future<PayrollRun> approve(int runId) async =>
      _run(await _api.authedPost('/payroll/runs/$runId/approve', body: '{}'));

  Future<PayrollRun> cancel(int runId) async =>
      _run(await _api.authedPost('/payroll/runs/$runId/cancel', body: '{}'));

  /// Each line from the account named for it.
  Future<PayrollRun> pay(
    int runId, {
    required Map<int, int> accountByLine,
    required String paidDate,
  }) async => _run(
    await _api.authedPost(
      '/payroll/runs/$runId/pay',
      body: jsonEncode({
        'paid_date': paidDate,
        'lines': [
          for (final e in accountByLine.entries)
            {'payroll_id': e.key, 'payment_account_id': e.value},
        ],
      }),
    ),
  );

  Future<Map<String, dynamic>> payslip(int lineId) async =>
      _body(await _api.authedGet('/payroll/$lineId/payslip'))
          as Map<String, dynamic>;

  Future<List<Map<String, dynamic>>> paymentAccounts() =>
      _api.getPaymentAccounts();

  // ── an employee's payroll data ────────────────────────────────────────────

  /// His structures, and the day a new one is offered from -- the server's:
  /// the month after his last approved salary (HR-UX ط1).
  Future<(List<SalaryStructureModel>, String?)> structures(
    int employeeId,
  ) async {
    final body =
        _body(await _api.authedGet('/employees/$employeeId/salary-structures'))
            as Map<String, dynamic>;
    return (
      (body['structures'] as List)
          .map((e) => SalaryStructureModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      body['suggested_from'] as String?,
    );
  }

  /// A gross split by the owner's ratios -- the server's, kept whole.
  Future<Map<String, double>> suggest(double gross) async {
    final body =
        _body(
              await _api.authedGet(
                '/payroll/structure-suggestion',
                queryParams: {'gross': '$gross'},
              ),
            )
            as Map<String, dynamic>;
    return {for (final e in body.entries) e.key: (e.value as num).toDouble()};
  }

  Future<void> addStructure(
    int employeeId, {
    required String effectiveFrom,
    required double basic,
    required double housing,
    required double transport,
    required double otherAllowances,
  }) async {
    _body(
      await _api.authedPost(
        '/employees/$employeeId/salary-structures',
        body: jsonEncode({
          'effective_from': effectiveFrom,
          'basic': basic,
          'housing': housing,
          'transport': transport,
          'other_allowances': otherAllowances,
        }),
      ),
    );
  }

  Future<void> deleteStructure(int structureId) async {
    _body(await _api.authedDelete('/salary-structures/$structureId'));
  }

  /// payment_method, iban, bank_name -- as his file says them.
  Future<Map<String, dynamic>> payment(int employeeId) async =>
      _body(await _api.authedGet('/employees/$employeeId'))
          as Map<String, dynamic>;

  /// His payment method ('bank' / 'cash'), IBAN and bank.
  Future<void> savePayment(
    int employeeId, {
    required String? method,
    required String? iban,
    required String? bankName,
    required int? schemeId,
    required double? contributionWage,
  }) async {
    _body(
      await _api.authedPut(
        '/employees/$employeeId',
        body: jsonEncode({
          'payment_method': method,
          'iban': iban,
          'bank_name': bankName,
          'contribution_scheme_id': schemeId,
          'contribution_wage': contributionWage,
        }),
      ),
    );
  }

  /// id and name of each active contribution scheme.
  Future<List<Map<String, dynamic>>> schemes() async =>
      (_body(await _api.authedGet('/contribution-schemes')) as List)
          .cast<Map<String, dynamic>>()
          .where((s) => s['is_active'] != false)
          .toList();

  /// His plans, his advance account's balance, and what of it is unplanned.
  Future<(List<AdvancePlanModel>, double, double)> advancePlans(
    int employeeId,
  ) async {
    final body =
        _body(await _api.authedGet('/employees/$employeeId/advance-plans'))
            as Map<String, dynamic>;
    return (
      (body['plans'] as List)
          .map((e) => AdvancePlanModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      (body['account_balance'] as num).toDouble(),
      (body['unplanned'] as num).toDouble(),
    );
  }

  Future<void> addAdvancePlan(
    int employeeId, {
    required double amount,
    required double? installment,
    required int startMonth,
    required int startYear,
    required bool consent,
    required String? consentNote,
  }) async {
    _body(
      await _api.authedPost(
        '/employees/$employeeId/advance-plans',
        body: jsonEncode({
          'amount': amount,
          'installment': installment,
          'start_month': startMonth,
          'start_year': startYear,
          'consent': consent,
          'consent_note': consentNote,
        }),
      ),
    );
  }

  Future<void> cancelAdvancePlan(int planId) async {
    _body(await _api.authedPost('/advance-plans/$planId/cancel', body: '{}'));
  }

  // ── contribution schemes: dated rates on their base (PAYROLL-2) ─────────

  /// Every scheme, the stopped ones too, each with its components.
  Future<List<Map<String, dynamic>>> allSchemes() async =>
      (_body(await _api.authedGet('/contribution-schemes')) as List)
          .cast<Map<String, dynamic>>();

  Future<void> createScheme(String name) async {
    _body(
      await _api.authedPost(
        '/contribution-schemes',
        body: jsonEncode({'name': name}),
      ),
    );
  }

  Future<void> setSchemeActive(int schemeId, bool active) async {
    _body(
      await _api.authedPut(
        '/contribution-schemes/$schemeId',
        body: jsonEncode({'is_active': active}),
      ),
    );
  }

  /// A rate from a day on -- a new rate of a component is a new row of its code.
  Future<void> addComponent(int schemeId, Map<String, dynamic> row) async {
    _body(
      await _api.authedPost(
        '/contribution-schemes/$schemeId/components',
        body: jsonEncode(row),
      ),
    );
  }

  Future<void> updateComponent(
    int componentId,
    Map<String, dynamic> row,
  ) async {
    _body(
      await _api.authedPut(
        '/contribution-components/$componentId',
        body: jsonEncode(row),
      ),
    );
  }

  // ── the policy (the owner's figures; none seeded for end of service) ────

  /// The keys set, as the server holds them; a key absent is not set.
  Future<Map<String, dynamic>> policy() async =>
      ((_body(await _api.authedGet('/payroll/policy'))
              as Map<String, dynamic>)['policy']
          as Map<String, dynamic>?) ??
      const {};

  /// Each key given checked by the server; the refusal said as it is.
  Future<Map<String, dynamic>> savePolicy(Map<String, dynamic> changes) async =>
      (_body(await _api.authedPut('/payroll/policy', body: jsonEncode(changes)))
              as Map<String, dynamic>)['policy']
          as Map<String, dynamic>;

  /// His file in one place (EMP-2): each part as its owner says it.
  Future<Map<String, dynamic>> employeeFile(int employeeId) async =>
      _body(await _api.authedGet('/employees/$employeeId/file'))
          as Map<String, dynamic>;

  // ── contracts and documents (EMP-3) ───────────────────────────────────

  Future<void> addContract(int employeeId, Map<String, dynamic> row) async {
    _body(
      await _api.authedPost(
        '/employees/$employeeId/contracts',
        body: jsonEncode(row),
      ),
    );
  }

  /// Every kind of document, its alert days (null: no alert).
  Future<List<Map<String, dynamic>>> documentTypes() async =>
      (_body(await _api.authedGet('/employee-document-types')) as List)
          .cast<Map<String, dynamic>>();

  Future<void> saveDocumentType(Map<String, dynamic> row, {int? id}) async {
    _body(
      id == null
          ? await _api.authedPost(
              '/employee-document-types',
              body: jsonEncode(row),
            )
          : await _api.authedPut(
              '/employee-document-types/$id',
              body: jsonEncode(row),
            ),
    );
  }

  Future<void> addDocument(int employeeId, Map<String, dynamic> row) async {
    _body(
      await _api.authedPost(
        '/employees/$employeeId/documents',
        body: jsonEncode(row),
      ),
    );
  }

  // ── leave (EMP-4) ─────────────────────────────────────────────────────

  /// Every kind of leave, its days the owner's (null: no balance held).
  Future<List<Map<String, dynamic>>> leaveTypes() async =>
      (_body(await _api.authedGet('/leave-types')) as List)
          .cast<Map<String, dynamic>>();

  Future<void> saveLeaveType(Map<String, dynamic> row, {int? id}) async {
    _body(
      id == null
          ? await _api.authedPost('/leave-types', body: jsonEncode(row))
          : await _api.authedPut('/leave-types/$id', body: jsonEncode(row)),
    );
  }

  /// Recorded by the manager, approved; refused beyond a held balance.
  Future<void> recordLeave(int employeeId, Map<String, dynamic> row) async {
    _body(
      await _api.authedPost(
        '/employees/$employeeId/leaves',
        body: jsonEncode(row),
      ),
    );
  }

  Future<void> cancelLeave(int leaveId) async {
    _body(
      await _api.authedPost('/employee-leaves/$leaveId/cancel', body: '{}'),
    );
  }

  // ── end of service (EMP-5) ────────────────────────────────────────────

  /// The settlement as it would be -- nothing written.
  Future<Map<String, dynamic>> previewTermination(
    int employeeId,
    Map<String, dynamic> row,
  ) async =>
      _body(
            await _api.authedPost(
              '/employees/$employeeId/termination/preview',
              body: jsonEncode(row),
            ),
          )
          as Map<String, dynamic>;

  Future<Map<String, dynamic>> approveTermination(
    int employeeId,
    Map<String, dynamic> row,
  ) async =>
      _body(
            await _api.authedPost(
              '/employees/$employeeId/termination',
              body: jsonEncode(row),
            ),
          )
          as Map<String, dynamic>;

  Future<void> payTermination(int terminationId, int paymentAccountId) async {
    _body(
      await _api.authedPost(
        '/employee-terminations/$terminationId/pay',
        body: jsonEncode({'payment_account_id': paymentAccountId}),
      ),
    );
  }

  Future<void> cancelTermination(int terminationId) async {
    _body(
      await _api.authedPost(
        '/employee-terminations/$terminationId/cancel',
        body: '{}',
      ),
    );
  }

  /// The HR hub's indicators, employees and what needs doing (HR-UX ر1).
  Future<Map<String, dynamic>> hrOverview() async =>
      _body(await _api.authedGet('/hr/overview')) as Map<String, dynamic>;

  // ── the employee's portal: his own (EMP-PORTAL-1) ─────────────────────

  Future<Map<String, dynamic>> myPortal() async =>
      _body(await _api.authedGet('/me/portal')) as Map<String, dynamic>;

  Future<Map<String, dynamic>> myPayslip(int payrollId) async =>
      _body(await _api.authedGet('/me/payslips/$payrollId'))
          as Map<String, dynamic>;

  /// Always a request: the manager approves it.
  Future<void> requestMyLeave(Map<String, dynamic> row) async {
    _body(await _api.authedPost('/me/leaves', body: jsonEncode(row)));
  }

  Future<void> cancelMyLeave(int leaveId) async {
    _body(await _api.authedPost('/me/leaves/$leaveId/cancel', body: '{}'));
  }

  /// The manager's decision on a request.
  Future<void> decideLeave(int leaveId, {required bool approve}) async {
    _body(
      await _api.authedPost(
        '/employee-leaves/$leaveId/${approve ? 'approve' : 'reject'}',
        body: '{}',
      ),
    );
  }

  // ── plumbing ──────────────────────────────────────────────────────────────

  PayrollRun _run(http.Response resp) =>
      PayrollRun.fromJson(_body(resp) as Map<String, dynamic>);

  Object? _body(http.Response resp) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(resp.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    if (resp.statusCode >= 200 && resp.statusCode < 300) return decoded;
    final reason = decoded is Map<String, dynamic>
        ? (decoded['error'] ?? decoded['message'])?.toString()
        : null;
    throw PayrollApiException(
      reason?.isNotEmpty == true ? reason! : 'تعذّر الطلب (${resp.statusCode})',
      statusCode: resp.statusCode,
    );
  }
}

class PayrollApiException implements Exception {
  const PayrollApiException(this.message, {required this.statusCode});
  final String message;
  final int statusCode;
  @override
  String toString() => message;
}
