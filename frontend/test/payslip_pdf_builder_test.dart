import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/pdf/payslip_pdf_builder.dart';

/// HR-UX ر3: the payslip on paper -- what the server says, laid out.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a payslip is a PDF of its lines', () async {
    final bytes = await buildPayslipPdf({
      'entry': {
        'month': 10,
        'year': 2026,
        'basic_salary': 5185.19,
        'net_salary': 7000.0,
        'voucher': {'voucher_number': 'PAY-2026-10-0002'},
      },
      'employee': {
        'name': 'مسعد المهري',
        'employee_code': 'EMP-2026-0002',
        'payment_method': 'bank',
        'iban': 'SA0380000000608010167519',
      },
      'breakdown': {
        'earned': {
          'basic': 5185.19,
          'housing': 1296.30,
          'transport': 518.51,
          'other_allowances': 0,
        },
        'days': 30,
        'divisor': 30,
        'whole_month': true,
        'additions': <dynamic>[],
        'bonuses': <dynamic>[],
        'deductions': [
          {'kind': 'absence', 'label': 'غياب يوم', 'amount': 200.0},
        ],
      },
    });
    expect(String.fromCharCodes(bytes.take(4)), '%PDF');
    expect(bytes.length, greaterThan(1000));
  });
}
