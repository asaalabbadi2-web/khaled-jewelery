// «تنفيذ التسكير الوزني» أُزيل (ADR-048 المرحلة 3ج): زرّه المحفوظ في الوصول
// السريع على الجهاز يسقط عند التحميل، ولا يبقى زرًّا لا يفتح شيئًا.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:frontend/models/quick_action_item.dart';
import 'package:frontend/providers/quick_actions_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _saved(String id, String route) => QuickActionItem(
      id: id,
      icon: Icons.scale,
      label: id,
      route: route,
      colorHex: '#C9A227',
      isActive: true,
      order: 1,
      group: QuickActionGroup.accounting,
    ).toMap();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a saved button whose screen is gone is dropped; the rest stay', () async {
    final kept = DefaultQuickActions.getAll().first;
    SharedPreferences.setMockInitialValues({
      'quick_actions': jsonEncode([
        _saved('weight_closing_execute', 'weight_closing_execute'),
        kept.toMap(),
      ]),
    });
    final provider = QuickActionsProvider();
    while (provider.isLoading) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final ids = provider.actions.map((a) => a.id).toList();
    expect(ids, isNot(contains('weight_closing_execute')));
    expect(ids, contains(kept.id));
  });

  test('the catalog offers it no more', () {
    expect(DefaultQuickActions.findById('weight_closing_execute'), isNull);
  });
}
