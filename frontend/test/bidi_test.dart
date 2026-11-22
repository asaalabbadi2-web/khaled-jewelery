// A code, a date, a weight or a name in Latin inside an Arabic sentence is kept as written (the owner,
// 22 Nov 2026, the screens seen by a designer's eye: «جم 12.50 · KJ-000103», «من 40 38», «بيعت 21-11-2026»).
// Each Latin run is isolated (U+2066 .. U+2069): the Arabic around it keeps its order, the run its own.

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/utils/bidi.dart';

final l = String.fromCharCode(0x2066), p = String.fromCharCode(0x2069);

void main() {
  test('a run is isolated as one: a code, a date with its time, a weight', () {
    expect(isolateLatin('KJ-000103 · 12.50 جم'), '${l}KJ-000103$p · ${l}12.50$p جم');
    expect(isolateLatin('بيعت 2026-11-21'), 'بيعت ${l}2026-11-21$p');
    expect(isolateLatin('بدأه saleh 2027-01-04 21:05'), 'بدأه ${l}saleh$p ${l}2027-01-04 21:05$p');
    expect(isolateLatin('38 من 40'), '${l}38$p من ${l}40$p');
  });

  test('Arabic alone is left as it is, and a run already isolated is not isolated again', () {
    expect(isolateLatin('ليست في المخزون'), 'ليست في المخزون');
    expect(isolateLatin(isolateLatin('KJ-000103')), '${l}KJ-000103$p');
  });

  test('built on the one isolate the app has: ltrIsolate', () {
    expect(isolateLatin('KJ-000001'), ltrIsolate('KJ-000001'));
  });
}
