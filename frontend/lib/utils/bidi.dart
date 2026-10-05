/// Keeps a number (or any left-to-right run) whole inside Arabic text:
/// «1,500.00 ر.س» never reorders into «ر.س 00.1,500».
String ltrIsolate(String text) =>
    '${String.fromCharCode(0x2066)}$text${String.fromCharCode(0x2069)}';
