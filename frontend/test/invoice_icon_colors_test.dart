import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/quick_action_item.dart';
import 'package:flutter/material.dart';
import 'package:frontend/theme/app_theme.dart';

/// The owner (29 Oct 2026): «كل أيقونة لونها يطابق اللون الخاص بالفاتورة»,
/// and the piggy bank replaced, wherever it is, by a sign that means what
/// it stands for. A quick action's invoice icon had its own color, apart
/// from the invoice's: a scrap purchase blue (#0288D1) on the home screen,
/// orange red on its own screen.
void main() {
  group('an invoice action takes its invoice\'s color', () {
    const kinds = {
      'sales_invoice': InvoiceKind.sale,
      'scrap_sales_invoice': InvoiceKind.saleScrap,
      'purchase_invoice': InvoiceKind.purchase,
      'scrap_purchase_invoice': InvoiceKind.purchaseScrap,
      'return_sales': InvoiceKind.returned,
      'return_purchase': InvoiceKind.returned,
      'return_purchase_supplier': InvoiceKind.returned,
      'return_invoice': InvoiceKind.returned,
    };

    for (final tones in [AppSemanticColors.light, AppSemanticColors.dark]) {
      test(tones == AppSemanticColors.light ? 'light' : 'dark', () {
        for (final MapEntry(key: id, value: kind) in kinds.entries) {
          final action = DefaultQuickActions.findById(id)!;
          expect(action.invoiceKind, kind, reason: id);
          expect(action.colorIn(tones), tones.invoice(kind).fg, reason: id);
        }
      });
    }

    test('even when the device kept an older color', () {
      final kept = QuickActionItem.fromMap({'id': 'scrap_purchase_invoice', 'colorHex': '#0288D1'});
      expect(kept.colorIn(AppSemanticColors.light), AppSemanticColors.light.invoice(InvoiceKind.purchaseScrap).fg);
    });

    test('an action that is no invoice keeps its own color', () {
      final list = DefaultQuickActions.findById('invoices_list')!;
      expect(list.invoiceKind, isNull);
      expect(list.colorIn(AppSemanticColors.light), list.getColor());
    });
  });

  test('no piggy bank anywhere', () {
    final piggy = RegExp(r'Icons\.savings\b');
    final found = [
      for (final f in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart'))
          for (final (i, line) in f.readAsLinesSync().indexed)
            if (piggy.hasMatch(line)) '${f.path}:${i + 1}',
    ];
    expect(found, isEmpty);
  });

  test('a device that kept the piggy bank for the safes shows the new sign', () {
    final kept = QuickActionItem.fromMap({'id': 'safe_boxes', 'iconCodePoint': 0xe553 /* Icons.savings, as kept */});
    expect(kept.icon, DefaultQuickActions.findById('safe_boxes')!.icon);
  });

  // The owner (17 Nov 2026): «أيقونة السندات في الوضع الداكن تكاد لا ترى».
  // A quick action's own color was fixed for the light theme: the vouchers'
  // brown #5D4037 on the dark tile, 1.6:1. Every action's icon reads at 3:1
  // on its tile -- the tile's surface under the icon's own tint -- in both.
  for (final (name, theme) in [('light', LightTheme.theme), ('dark', DarkTheme.theme)]) {
    test('every quick action\'s icon is seen on its tile, $name', () {
      final s = theme.colorScheme;
      final tile = theme.brightness == Brightness.dark ? s.surfaceContainerHigh : s.surfaceContainerLow;
      final tones = theme.extension<AppSemanticColors>()!;
      double contrast(Color a, Color b) {
        final la = a.computeLuminance(), lb = b.computeLuminance();
        return ((la > lb ? la : lb) + 0.05) / ((la > lb ? lb : la) + 0.05);
      }
      final faint = <String>[];
      for (final action in DefaultQuickActions.getAll()) {
        final c = action.colorIn(tones, on: tile);
        final box = Color.alphaBlend(c.withValues(alpha: 0.18), tile);
        if (contrast(c, box) < 3) faint.add('${action.id} ${contrast(c, box).toStringAsFixed(2)}');
      }
      expect(faint, isEmpty);
    });
  }
}
