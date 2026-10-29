// أسماء أنواع الفواتير كما يقرؤها الشخص (المالك، 17 أكتوبر 2026): «شراء من
// عميل» تُعرض «شراء كسر»، والشراء من المورد «شراء جديد»، وتسوية المكتب «شراء
// كسر من مكتب»، والمرتجعان يتبعان -- والنوع المخزّن لا يتغيّر.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/quick_action_item.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:frontend/theme/app_semantic_colors.dart';
import 'package:frontend/utils/invoice_type_label.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the owner\'s names, from the stored type', () {
    expect(invoiceTypeLabelOf('شراء من عميل'), 'شراء كسر');
    expect(invoiceTypeLabelOf('شراء'), 'شراء جديد');
    expect(invoiceTypeLabelOf('شراء من مورد'), 'شراء جديد');
    expect(invoiceTypeLabelOf('شراء', officeId: 7), 'شراء كسر من مكتب');
    expect(invoiceTypeLabelOf('مرتجع شراء'), 'مرتجع شراء كسر');
    expect(invoiceTypeLabelOf('مرتجع شراء (مورد)'), 'مرتجع شراء جديد');
    expect(invoiceTypeLabelOf('بيع'), 'بيع');
    expect(invoiceTypeLabelOf(null), '');
  });

  test('the server\'s own name first; derived only when it sends none', () {
    expect(invoiceTypeLabel({'invoice_type': 'شراء', 'invoice_type_label': 'شراء كسر من مكتب'}), 'شراء كسر من مكتب');
    expect(invoiceTypeLabel({'invoice_type': 'شراء', 'office_id': 3}), 'شراء كسر من مكتب');
    expect(invoiceTypeLabel({'invoice_type': 'شراء من عميل'}), 'شراء كسر');
  });

  test('a quick-access button saved under its old name reads the new one', () async {
    final saved = DefaultQuickActions.findById('return_purchase')!.copyWith(label: 'مرتجع شراء');
    SharedPreferences.setMockInitialValues({'quick_actions': jsonEncode([saved.toMap()])});
    final provider = QuickActionsProvider();
    while (provider.isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(provider.actions.single.label, 'مرتجع شراء كسر');
  });

  test('the old names are shown nowhere: no screen writes them as its own text', () {
    // The stored types («شراء من عميل», «مرتجع شراء (مورد)») stay as keys; these
    // were only ever shown, and must not come back.
    const shownOnly = [
      "'شراء مورد'", "'مرتجع شراء عميل'", "'مرتجع شراء مورد'", "'شراء كسر من عميل'",
      "'شراء عميل'", "'مرتجع فاتورة شراء من عميل'", "(شراء من عميل)'", "? 'فاتورة شراء' :",
      "isAr ? 'مرتجع شراء (مورد)'", "'name_ar': 'مرتجع شراء (مورد)'", "'name_ar': 'شراء',",
    ];
    final found = <String>[];
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!f.path.endsWith('.dart') || f.path.contains('_archived') || f.path.contains('.backup.')) continue;
      final text = f.readAsStringSync();
      for (final s in shownOnly) {
        if (text.contains(s)) found.add('${f.path}: $s');
      }
    }
    expect(found, isEmpty);
  });

  test('the kind, and so the color, an invoice is shown in', () {
    InvoiceKind? k(Map<String, Object?> m) => invoiceKindOf(m);
    expect(k({'invoice_type': 'بيع'}), InvoiceKind.sale);
    expect(k({'invoice_type': 'بيع', 'gold_type': 'scrap'}), InvoiceKind.saleScrap);
    expect(k({'invoice_type': 'بيع', 'gold_type': 'new'}), InvoiceKind.sale);
    expect(k({'invoice_type': 'شراء'}), InvoiceKind.purchase);
    expect(k({'invoice_type': 'شراء من مورد'}), InvoiceKind.purchase);
    expect(k({'invoice_type': 'شراء', 'office_id': 3}), InvoiceKind.purchaseScrap);
    expect(k({'invoice_type': 'شراء', 'invoice_type_label': 'شراء كسر من مكتب'}), InvoiceKind.purchaseScrap);
    expect(k({'invoice_type': 'شراء من عميل'}), InvoiceKind.purchaseScrap);
    for (final r in ['مرتجع بيع', 'مرتجع شراء', 'مرتجع شراء (مورد)', 'مرتجع شراء من مورد']) {
      expect(k({'invoice_type': r}), InvoiceKind.returned, reason: r);
    }
    expect(k({'invoice_type': 'سند'}), isNull);
  });
}
