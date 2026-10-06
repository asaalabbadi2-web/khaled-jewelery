import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/widgets/settlement_schedule_editor.dart';

/// What the payment-method screen sends for a schedule (ADR-037): the server
/// reads it; the screen computes no date. A fixed plan sends no minimum; a
/// weekly batch sends its last day, a daily one none.
void main() {
  test('Tamara, flexible: a weekly batch ending Friday, deposited Wednesday', () {
    final v = SettlementScheduleValue.fromMethod({
      'settlement_schedule_type': 'weekday', 'settlement_weekday': 4,
      'deposit_schedule_type': 'weekday', 'deposit_weekday': 2,
      'min_settlement_amount': 2500.0, 'bank_weekend_days': '', 'skip_public_holidays': false,
    });
    expect(v.flexible, isTrue);
    expect(v.toPayload(), {
      'settlement_schedule_type': 'weekday', 'settlement_weekday': 4,
      'deposit_schedule_type': 'weekday', 'deposit_delay_days': 0, 'deposit_weekday': 2,
      'bank_weekend_days': <int>[], 'skip_public_holidays': false, 'min_settlement_amount': 2500.0,
    });
  });

  test('a fixed plan sends no minimum, whatever was typed', () {
    final v = SettlementScheduleValue.fromMethod({'min_settlement_amount': 2500.0})
        .copyWith(flexible: false);
    expect(v.toPayload()['min_settlement_amount'], 0.0);
  });

  test('Mada: daily, the next day; a bank weekend is sent sorted', () {
    final v = SettlementScheduleValue.fromMethod({
      'settlement_schedule_type': 'days', 'settlement_weekday': 5,
      'deposit_schedule_type': 'days', 'deposit_delay_days': 1, 'bank_weekend_days': '5,4',
    });
    final p = v.toPayload();
    expect(p['settlement_weekday'], isNull);
    expect(p['deposit_delay_days'], 1);
    expect(p['deposit_weekday'], isNull);
    expect(p['bank_weekend_days'], [4, 5]);
  });
}
