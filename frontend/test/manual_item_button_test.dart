import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:frontend/providers/settings_provider.dart';
import 'package:frontend/screens/sales_invoice_screen_v2.dart';

void main() {
  testWidgets('SalesInvoiceScreenV2 builds with manual item button', (
    tester,
  ) async {
    final settingsProvider = SettingsProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settingsProvider,
        child: const MaterialApp(
          home: Scaffold(
            body: SalesInvoiceScreenV2(items: [], customers: []),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.edit_note), findsOneWidget);
  });

  testWidgets('Manual item dialog can submit without crashing', (tester) async {
    final settingsProvider = SettingsProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<SettingsProvider>.value(
        value: settingsProvider,
        child: const MaterialApp(
          home: Scaffold(
            body: SalesInvoiceScreenV2(items: [], customers: []),
          ),
        ),
      ),
    );

    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.edit_note));
    await tester.pumpAndSettle();

    expect(find.text('إضافة صنف يدوي'), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextFormField, 'اسم الصنف'),
      'سوار يدوي',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'الباركود / رقم الصنف (اختياري)'),
      'MAN-001',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'الوزن بالجرام'),
      '5.5',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'أجرة المصنعية للجرام (اختياري)'),
      '10',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, 'الإجمالي مع الضريبة (اختياري)'),
      '1000',
    );

    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byIcon(Icons.check_circle_outline),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إضافة صنف يدوي'), findsNothing);
  });
}
