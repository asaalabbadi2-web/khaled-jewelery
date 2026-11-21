import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/category_model.dart';

/// Categories put in order (ADR-045 B, 14 Oct 2026): a category can be
/// stopped (never deleted once used), marked as its karat's scrap category;
/// its section is the owner's (ADR-093 amendment) -- no group derived from
/// its name any more.
void main() {
  test('a category carries its state, its scrap mark and its section', () {
    final c = Category.fromJson({
      'id': 61, 'name': 'حلق اسباني (موقوف) 18', 'karat': '18', 'is_active': false,
      'is_scrap': false, 'section_id': 4, 'section_name': 'حلق', 'items_count': 0,
    });
    expect((c.isActive, c.isScrap, c.sectionId, c.sectionName), (false, false, 4, 'حلق'));
    final scrap = Category.fromJson({'id': 67, 'name': 'كسر 21', 'karat': '21', 'is_scrap': true});
    expect((scrap.isActive, scrap.isScrap), (true, true), reason: 'active unless the server says otherwise');
  });
}
