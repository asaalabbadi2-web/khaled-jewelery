import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The field under [key]'s editable text.
/// Found scrolled out of sight too: a door kept alive there still hears the reader.
EditableText doorOf(WidgetTester tester, String key) => tester.widget<EditableText>(
      find
          .descendant(
            of: find.byKey(Key(key), skipOffstage: false),
            matching: find.byType(EditableText, skipOffstage: false),
            matchRoot: true,
          )
          .first,
    );

bool focused(WidgetTester tester, String key) => doorOf(tester, key).focusNode.hasFocus;

/// What the focused field asked of the platform: no on-screen keyboard -- on the web
/// `inputmode="none"`, which the owner's reader opened none with (21 Nov 2026).
bool asksNoKeyboard(WidgetTester tester) {
  final args = tester.testTextInput.setClientArgs;
  return args != null && (args['inputType'] as Map)['name'] == 'TextInputType.none';
}

/// The reader types [value] into the field under [key] as it does on the owner's reader:
/// one character after another, a few milliseconds apart, no Enter -- then nothing.
Future<void> readerTypes(WidgetTester tester, String key, String value) async {
  final field = find.byKey(Key(key), skipOffstage: false);
  for (var i = 1; i <= value.length; i++) {
    await tester.enterText(field, value.substring(0, i));
    await tester.pump(const Duration(milliseconds: 3));
  }
  await tester.pump(const Duration(milliseconds: 300)); // the reader's quiet after a value
  // settled -- or the server still asked, its spinner turning: a few frames, not forever
  for (var i = 0; i < 20 && tester.binding.hasScheduledFrame; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Typed by hand into the scan field under [key]: its keyboard asked, the number written, «✓».
Future<void> typeByHand(WidgetTester tester, String key, String text) async {
  await tester.tap(find.byKey(Key('$key-keyboard')));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(Key(key)), text);
  await tester.tap(find.byKey(Key('$key-take')));
  await tester.pumpAndSettle();
}
