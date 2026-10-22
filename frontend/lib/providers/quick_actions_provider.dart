import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/quick_action_item.dart';

enum QuickActionAddStatus { added, reactivated, alreadyExists, failed }

/// Provider لإدارة أزرار الوصول السريع في الشاشة الرئيسية
class QuickActionsProvider extends ChangeNotifier {
  static const String _storageKey = 'quick_actions';
  static const String _showSalesRaceCardKey = 'home_show_sales_race_card';

  List<QuickActionItem> _actions = [];
  bool _isLoading = true;
  bool _showSalesRaceCard = true;

  List<QuickActionItem> get actions => _actions;
  List<QuickActionItem> get activeActions =>
      _actions.where((item) => item.isActive).toList()
        ..sort((a, b) => a.order.compareTo(b.order));

  bool get isLoading => _isLoading;

  bool get showSalesRaceCard => _showSalesRaceCard;

  QuickActionsProvider() {
    _loadActions();
  }

  List<QuickActionItem> get availableActions {
    final existingIds = _actions.map((item) => item.id).toSet();
    return DefaultQuickActions.catalogExcluding(existingIds);
  }

  int _nextOrderIndex() {
    if (_actions.isEmpty) {
      return 0;
    }
    return _actions.map((item) => item.order).reduce(math.max) + 1;
  }

  void _sortActionsByOrder() {
    _actions.sort((a, b) => a.order.compareTo(b.order));
  }

  /// تحميل الأزرار من SharedPreferences
  Future<void> _loadActions() async {
    _isLoading = true;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();

      _showSalesRaceCard =
          prefs.getBool(_showSalesRaceCardKey) ?? _showSalesRaceCard;

      final String? actionsJson = prefs.getString(_storageKey);

      if (actionsJson != null && actionsJson.isNotEmpty) {
        final List<dynamic> decoded = json.decode(actionsJson);
        // A button whose screen is gone (e.g. «تنفيذ التسكير الوزني», ADR-048)
        // stays saved on the device: drop what the catalog no longer has.
        _actions = decoded
            .map((item) => QuickActionItem.fromMap(item))
            .where((item) => DefaultQuickActions.findById(item.id) != null)
            // The label is the catalog's: a renamed button (e.g. «شراء جديد»,
            // 17 Oct 2026) does not keep the name it was saved under.
            .map((item) => item.copyWith(label: DefaultQuickActions.findById(item.id)!.label))
            .toList();
        debugPrint('✅ تم تحميل ${_actions.length} زر من الإعدادات');
      } else {
        // إذا لم تكن هناك إعدادات محفوظة، استخدم الافتراضيات
        _actions = DefaultQuickActions.getDefaultActive();
        await _saveActions(); // احفظ الافتراضيات
        debugPrint('✅ تم تحميل الأزرار الافتراضية (${_actions.length} زر)');
      }
    } catch (e) {
      debugPrint('❌ خطأ في تحميل الأزرار: $e');
      _actions = DefaultQuickActions.getDefaultActive();
    }

    _sortActionsByOrder();
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> setShowSalesRaceCard(bool value) async {
    _showSalesRaceCard = value;
    notifyListeners();

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_showSalesRaceCardKey, value);
      return true;
    } catch (e) {
      debugPrint('❌ خطأ في حفظ خيار سباق المبيعات: $e');
      return false;
    }
  }

  /// حفظ الأزرار في SharedPreferences
  Future<bool> _saveActions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> encoded = _actions
          .map((item) => item.toMap())
          .toList();
      final String actionsJson = json.encode(encoded);

      await prefs.setString(_storageKey, actionsJson);
      debugPrint('✅ تم حفظ ${_actions.length} زر');
      return true;
    } catch (e) {
      debugPrint('❌ خطأ في حفظ الأزرار: $e');
      return false;
    }
  }

  /// تفعيل أو تعطيل زر
  Future<bool> toggleAction(String id) async {
    final index = _actions.indexWhere((item) => item.id == id);
    if (index == -1) return false;

    final before = _actions[index];
    _actions[index] = before.copyWith(isActive: !before.isActive);

    notifyListeners();
    final saved = await _saveActions();
    // Not saved, not shown (ADR-057 ر٤): the switch goes back, and the screen
    // says so -- it stayed turned while the device kept the old setting.
    if (!saved) {
      final i = _actions.indexWhere((item) => item.id == id);
      if (i != -1) _actions[i] = before;
      notifyListeners();
    }
    return saved;
  }

  /// إعادة ترتيب الأزرار
  Future<bool> reorderActions(int oldIndex, int newIndex) async {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }

    final item = _actions.removeAt(oldIndex);
    _actions.insert(newIndex, item);

    // تحديث order لجميع العناصر
    for (int i = 0; i < _actions.length; i++) {
      _actions[i] = _actions[i].copyWith(order: i);
    }

    notifyListeners();
    return await _saveActions();
  }

  /// إعادة ترتيب أزرار مجموعة واحدة فقط (group-scoped reorder)
  Future<bool> reorderGroupActions(
    QuickActionGroup group,
    int oldIndex,
    int newIndex,
  ) async {
    final groupItems = _actions
        .where((a) => a.group == group && a.isActive)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    if (oldIndex >= groupItems.length) return false;
    final adj = newIndex > oldIndex ? newIndex - 1 : newIndex;
    final moved = groupItems.removeAt(oldIndex);
    groupItems.insert(adj.clamp(0, groupItems.length), moved);

    // Apply group-scoped order values (0-based per group)
    for (int i = 0; i < groupItems.length; i++) {
      final idx = _actions.indexWhere((a) => a.id == groupItems[i].id);
      if (idx != -1) {
        _actions[idx] = _actions[idx].copyWith(order: i);
      }
    }

    notifyListeners();
    return await _saveActions();
  }

  /// The buttons as they were before a reset, put back -- its «تراجع»
  /// (ADR-057 ر٤). False when the device would not keep them.
  Future<bool> restoreActions(List<QuickActionItem> previous) async {
    _actions = [for (final item in previous) item.copyWith()];
    _sortActionsByOrder();
    notifyListeners();
    return await _saveActions();
  }

  /// إعادة تعيين إلى الإعدادات الافتراضية
  Future<bool> resetToDefaults() async {
    _actions = DefaultQuickActions.getDefaultActive();
    _sortActionsByOrder();
    notifyListeners();
    return await _saveActions();
  }

  /// تحديث زر معين
  Future<bool> updateAction(QuickActionItem updatedItem) async {
    final index = _actions.indexWhere((item) => item.id == updatedItem.id);
    if (index == -1) return false;

    _actions[index] = updatedItem;
    notifyListeners();
    return await _saveActions();
  }

  /// الحصول على زر بواسطة ID
  QuickActionItem? getActionById(String id) {
    try {
      return _actions.firstWhere((item) => item.id == id);
    } catch (e) {
      return null;
    }
  }

  /// إعادة تحميل الأزرار
  Future<void> reload() async {
    await _loadActions();
  }

  /// إضافة زر جديد من الكتالوج الافتراضي
  Future<QuickActionAddStatus> addActionFromCatalog(String id) async {
    final existingIndex = _actions.indexWhere((item) => item.id == id);

    if (existingIndex != -1) {
      final existing = _actions[existingIndex];
      if (!existing.isActive) {
        _actions[existingIndex] = existing.copyWith(isActive: true);
        _sortActionsByOrder();
        notifyListeners();
        final saved = await _saveActions();
        return saved
            ? QuickActionAddStatus.reactivated
            : QuickActionAddStatus.failed;
      }
      return QuickActionAddStatus.alreadyExists;
    }

    final template = DefaultQuickActions.findById(id);
    if (template == null) {
      return QuickActionAddStatus.failed;
    }

    final newItem = template.copyWith(isActive: true, order: _nextOrderIndex());

    _actions.add(newItem);
    _sortActionsByOrder();
    notifyListeners();
    final saved = await _saveActions();
    return saved ? QuickActionAddStatus.added : QuickActionAddStatus.failed;
  }
}
