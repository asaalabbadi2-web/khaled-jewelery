import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/category_model.dart';

/// Categories put in order (ADR-045 B, 14 Oct 2026): a category can be
/// stopped (never deleted once used), marked as its karat's scrap category,
/// and its group is derived by the server from its name.
void main() {
  test('a category carries its state, its scrap mark and its group', () {
    final c = Category.fromJson({
      'id': 61, 'name': 'حلق اسباني (موقوف) 18', 'karat': '18', 'is_active': false,
      'is_scrap': false, 'group_name': 'حلق اسباني (موقوف)', 'items_count': 0,
    });
    expect((c.isActive, c.isScrap, c.groupName), (false, false, 'حلق اسباني (موقوف)'));
    final scrap = Category.fromJson({'id': 67, 'name': 'كسر 21', 'karat': '21', 'is_scrap': true});
    expect((scrap.isActive, scrap.isScrap), (true, true), reason: 'active unless the server says otherwise');
  });
}
