import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/safe_box_model.dart';

/// A safe shows what waits for approval beside its posted balance (the owner,
/// 2 Oct 2026): posted + pending = what should be in hand. Read only.
void main() {
  Map<String, dynamic> safe(Map<String, dynamic> extra) =>
      {'id': 1, 'name': 'الصندوق', 'safe_type': 'cash', 'account_id': 9, ...extra};

  test('the pending cash, weights and documents are read', () {
    final s = SafeBoxModel.fromJson(safe({
      'pending': {'cash': -750.5, 'weight': {'21k': 2.5}, 'documents': 2},
    }));
    expect(s.pendingCash, -750.5);
    expect(s.pendingWeight, {'21k': 2.5});
    expect(s.pendingDocuments, 2);
  });

  test('a safe with nothing pending reads zero', () {
    final s = SafeBoxModel.fromJson(safe({}));
    expect(s.pendingCash, 0.0);
    expect(s.pendingDocuments, 0);
  });
}
