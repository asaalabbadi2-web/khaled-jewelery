import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:frontend/screens/template_designer_screen.dart';
import 'package:frontend/widgets/invoice_type_banner.dart';

void main() {
  testWidgets('InvoiceTypeBanner renders content', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: InvoiceTypeBanner(
            title: 'فاتورة بيع',
            subtitle: 'نص توضيحي',
            color: Colors.amber,
            icon: Icons.receipt_long,
          ),
        ),
      ),
    );

    expect(find.text('فاتورة بيع'), findsOneWidget);
    expect(find.text('نص توضيحي'), findsOneWidget);
    expect(find.byIcon(Icons.receipt_long), findsOneWidget);
  });

  testWidgets('TemplateDesignerScreen builds (smoke)', (tester) async {
    // shared_preferences يستخدم platform channel، نستخدم mock لتجنب مشاكل الاختبار.
    SharedPreferences.setMockInitialValues({});

    // TemplateDesignerScreen يحتوي على أعمدة/لوحات جانبية، نحتاج مساحة أكبر لتجنب overflow.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(2400, 1600);
    addTearDown(() {
      tester.view.resetDevicePixelRatio();
      tester.view.resetPhysicalSize();
    });

    await tester.pumpWidget(const MaterialApp(home: TemplateDesignerScreen()));

    // دع initState/post-frame callbacks تنفّذ بدون انتظار لا نهائي.
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.byType(TemplateDesignerScreen), findsOneWidget);
  });
}
