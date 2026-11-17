import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// No date is shown as the machine writes it -- «2026-10-08T10:00:00»,
/// «08:39:32.432715» -- but as displayDate writes it (the owner, 17 Nov
/// 2026: «اصلح التاريخ والوقت في السندات والفواتير وغيرها»).
void expectNoMachineDate(WidgetTester tester) {
  final machine = RegExp(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}|\d{2}:\d{2}:\d{2}\.\d');
  final shown = [
    for (final p in tester.renderObjectList<RenderParagraph>(find.byType(RichText)))
      if (machine.hasMatch(p.text.toPlainText())) p.text.toPlainText(),
  ];
  expect(shown, isEmpty, reason: 'dates shown as the machine writes them');
}
