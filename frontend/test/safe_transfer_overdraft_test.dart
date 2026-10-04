import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/safe_box_model.dart';

/// Only a karat that moves is checked against the source safe (the owner,
/// 4 Oct 2026): the display safe's 24k stood at −176 g and every gold transfer
/// from it was refused before it was sent -- 0.05 g of 21k out of 12,592 g --
/// because an empty 24k field (0) "exceeded" −176. The server learned this
/// rule on 2 Oct (`test_a_karat_not_moved_does_not_block_the_transfer`).
void main() {
  final display = SafeBoxModel.fromJson({
    'id': 30, 'name': 'خزينة الذهب المعروض للبيع', 'safe_type': 'gold', 'account_id': 760,
    'balance': {
      'cash': 0.0,
      'weight': {'18k': 11671.07, '21k': 12592.236, '22k': 62.6, '24k': -176.003, 'total': 0.0},
    },
  });

  test('a karat not moved does not block the transfer', () {
    expect(display.karatsShortFor({'21k': 0.05}), isEmpty);
    expect(display.karatsShortFor({'21k': 5.7}), isEmpty);
  });

  test('a karat moved beyond what the safe holds is refused', () {
    expect(display.karatsShortFor({'22k': 62.7}), ['22k']);
    expect(display.karatsShortFor({'24k': 0.01, '21k': 1.0}), ['24k']);
  });
}
