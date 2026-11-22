/// Keeps a number (or any left-to-right run) whole inside Arabic text:
/// «1,500.00 ر.س» never reorders into «ر.س 00.1,500».
String ltrIsolate(String text) =>
    '${String.fromCharCode(0x2066)}$text${String.fromCharCode(0x2069)}';

/// [text] -- often the server's words -- with each Latin run isolated by
/// [ltrIsolate] (the owner, 22 Nov 2026: «جم 12.50 · KJ-000103», «من 40 38»,
/// «بيعت 21-11-2026» on the scan screens). A run: letters or digits joined by
/// «-», «.», «:», «/» or «_» -- a code, a date (with its time after it), a
/// weight, a name typed in Latin; a run already isolated is left whole.
String isolateLatin(String text) => text.replaceAllMapped(
    _run, (m) => m[0]!.startsWith(_lri) ? m[0]! : ltrIsolate(m[0]!));

final _lri = String.fromCharCode(0x2066);
final _run = RegExp('${String.fromCharCode(0x2066)}[^${String.fromCharCode(0x2069)}]*${String.fromCharCode(0x2069)}'
    r'|[A-Za-z0-9](?:[A-Za-z0-9._:/-]*[A-Za-z0-9])?(?: [0-9]{2}:[0-9]{2})?');
