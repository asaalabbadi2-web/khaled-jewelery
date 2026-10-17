import 'package:flutter_test/flutter_test.dart';

import 'support/source_ratchet.dart';

/// UI-5 (ADR-049): updating a ratchet's baseline only lowers it. A file that
/// is not in it -- a new file, or someone's work in progress -- has a limit of
/// zero, and an update must not write its count in as a new limit.
void main() {
  test('a file goes down or drops out, never up', () {
    expect(
      lowerBaseline({'a': 3, 'b': 9}, {'a': 5, 'b': 7, 'c': 2}),
      {'a': 3, 'b': 7},
    );
  });

  test('a file not in the baseline is not let in', () {
    expect(lowerBaseline({'new.dart': 1}, {'old.dart': 4}), isEmpty);
  });
}
