// An amount with the new riyal sign reads in the dark theme (the owner, 30 Oct
// 2026: the manager's liquidity card -- «التباين غير موجود»). SarAwareText drew
// it with RichText, which takes no color from the theme: a style without one
// was black on the dark card. It is the theme's text, with the style on it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/theme/app_theme.dart';
import 'package:frontend/utils/currency_utils.dart' as cu;

void main() {
  testWidgets('an amount with the new sign wears the theme\'s text color', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: DarkTheme.theme,
        home: const Scaffold(
          body: cu.SarAwareText(
            '1,250.00 ر.س',
            isNewSar: true,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
    final rich = tester.widget<RichText>(find.byType(RichText).last);
    final span = rich.text as TextSpan;
    final color = (span.children!.first as TextSpan).style?.color ?? span.style?.color;
    expect(color, DarkTheme.theme.textTheme.bodyMedium?.color ?? DarkTheme.theme.colorScheme.onSurface);
  });
}
