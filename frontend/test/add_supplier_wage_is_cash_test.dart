import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/api_service.dart';
import 'package:frontend/screens/add_supplier_screen.dart';
import 'package:frontend/theme/app_theme.dart';

/// ADR-061: a supplier's wage is cash always; the supplier screen does not
/// offer to take it in gold -- such a supplier's purchases could not be saved.
void main() {
  testWidgets('the supplier screen offers no wage type', (tester) async {
    tester.view.physicalSize = const Size(1440, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: LightTheme.theme,
        home: Directionality(
          textDirection: TextDirection.rtl,
          child: AddSupplierScreen(api: ApiService(baseUrl: 'http://fake.test')),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('اسم المورد'), findsWidgets, reason: 'the form is drawn');
    expect(find.text('نوع أجور المصنعية الافتراضي'), findsNothing);
    expect(find.text('ذهب (وزن)'), findsNothing);
  });
}
