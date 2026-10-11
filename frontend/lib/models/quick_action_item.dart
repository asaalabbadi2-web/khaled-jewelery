import 'package:flutter/material.dart';

enum QuickActionGroup { sales, accounting, admin }

/// نموذج بيانات لعناصر الوصول السريع في الشاشة الرئيسية
class QuickActionItem {
  final String id;
  final IconData icon;
  final String label;
  final String route;
  final String colorHex; // نخزن اللون كـ hex string (#RRGGBB)
  final bool isActive;
  final int order; // ترتيب العنصر
  final QuickActionGroup group;

  QuickActionItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.route,
    required this.colorHex,
    this.isActive = true,
    this.order = 0,
    this.group = QuickActionGroup.sales,
  });

  factory QuickActionItem.fromMap(Map<String, dynamic> map) {
    final String? mapId = map['id'] as String?;
    QuickActionItem? fallback = mapId != null
        ? DefaultQuickActions.findById(mapId)
        : null;
    if (fallback == null && mapId != null) {
      fallback = _legacyFallbackFor(mapId);
    }
    final QuickActionItem? fallbackItem = fallback;
    final bool canonicalize =
        mapId != null && fallbackItem != null && fallbackItem.id != mapId;
    final QuickActionItem? canonicalFallback = canonicalize
        ? fallbackItem
        : null;

    final String resolvedId =
        canonicalFallback?.id ?? mapId ?? fallbackItem?.id ?? 'unknown';
    final String resolvedLabel =
        canonicalFallback?.label ??
        (map['label'] as String?) ??
        fallbackItem?.label ??
        resolvedId;
    final String resolvedRoute =
        canonicalFallback?.route ??
        (map['route'] as String?) ??
        fallbackItem?.route ??
        resolvedId;
    final String resolvedColorHex =
        canonicalFallback?.colorHex ??
        _resolveColorHex(
          map['colorHex'],
          map['color'],
          fallbackItem?.colorHex ?? '#FFD700',
        );
    final bool resolvedActive =
        canonicalFallback?.isActive ??
        map['isActive'] as bool? ??
        fallbackItem?.isActive ??
        true;
    final int resolvedOrder = map['order'] as int? ?? fallbackItem?.order ?? 0;
    final IconData resolvedIcon =
        canonicalFallback?.icon ?? _resolveIcon(map, fallbackItem);
    final QuickActionGroup resolvedGroup =
        canonicalFallback?.group ??
        _resolveGroup(map['group'] as String?, fallbackItem?.group);

    return QuickActionItem(
      id: resolvedId,
      icon: resolvedIcon,
      label: resolvedLabel,
      route: resolvedRoute,
      colorHex: resolvedColorHex,
      isActive: resolvedActive,
      order: resolvedOrder,
      group: resolvedGroup,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'iconCodePoint': icon.codePoint,
      'label': label,
      'route': route,
      'colorHex': colorHex,
      'isActive': isActive,
      'order': order,
      'group': group.name,
    };
  }

  Color getColor() {
    return Color(int.parse(colorHex.replaceFirst('#', '0xFF')));
  }

  QuickActionItem copyWith({
    String? id,
    IconData? icon,
    String? label,
    String? route,
    String? colorHex,
    bool? isActive,
    int? order,
    QuickActionGroup? group,
  }) {
    return QuickActionItem(
      id: id ?? this.id,
      icon: icon ?? this.icon,
      label: label ?? this.label,
      route: route ?? this.route,
      colorHex: colorHex ?? this.colorHex,
      isActive: isActive ?? this.isActive,
      order: order ?? this.order,
      group: group ?? this.group,
    );
  }

  @override
  String toString() {
    return 'QuickActionItem(id: $id, label: $label, isActive: $isActive, order: $order, group: ${group.name})';
  }

  static QuickActionGroup _resolveGroup(String? value, QuickActionGroup? fallback) {
    if (value != null) {
      switch (value) {
        case 'sales': return QuickActionGroup.sales;
        case 'accounting': return QuickActionGroup.accounting;
        case 'admin': return QuickActionGroup.admin;
      }
    }
    return fallback ?? QuickActionGroup.sales;
  }

  static IconData _resolveIcon(
    Map<String, dynamic> map,
    QuickActionItem? fallback,
  ) {
    final iconCodePoint = map['iconCodePoint'];
    if (iconCodePoint is int) {
      final mapped = _iconLookup[iconCodePoint];
      if (mapped != null) return mapped;
    }

    return fallback?.icon ?? Icons.extension;
  }

  // Map of common icon codePoints to their `Icons.*` constants.
  // This avoids constructing `IconData(...)` at runtime which prevents
  // the icon tree-shaker from working correctly.
  static final Map<int, IconData> _iconLookup = {
    Icons.point_of_sale.codePoint: Icons.point_of_sale,
    Icons.recycling_outlined.codePoint: Icons.recycling_outlined,
    Icons.shopping_cart.codePoint: Icons.shopping_cart,
    Icons.shopping_basket.codePoint: Icons.shopping_basket,
    Icons.receipt_long.codePoint: Icons.receipt_long,
    Icons.keyboard_return.codePoint: Icons.keyboard_return,
    Icons.undo.codePoint: Icons.undo,
    Icons.assignment_return.codePoint: Icons.assignment_return,
    Icons.assignment_return_outlined.codePoint:
        Icons.assignment_return_outlined,
    Icons.person_add.codePoint: Icons.person_add,
    Icons.people.codePoint: Icons.people,
    Icons.store.codePoint: Icons.store,
    Icons.add_box.codePoint: Icons.add_box,
    Icons.inventory_2.codePoint: Icons.inventory_2,
    Icons.south.codePoint: Icons.south,
    Icons.north.codePoint: Icons.north,
    Icons.edit_note.codePoint: Icons.edit_note,
    Icons.book.codePoint: Icons.book,
    Icons.assessment.codePoint: Icons.assessment,
    Icons.repeat.codePoint: Icons.repeat,
    Icons.menu_book.codePoint: Icons.menu_book,
    Icons.account_balance_wallet.codePoint: Icons.account_balance_wallet,
    Icons.account_tree.codePoint: Icons.account_tree,
    Icons.badge.codePoint: Icons.badge,
    Icons.manage_accounts.codePoint: Icons.manage_accounts,
    Icons.payments_rounded.codePoint: Icons.payments_rounded,
    Icons.event_available.codePoint: Icons.event_available,
    Icons.autorenew.codePoint: Icons.autorenew,
    Icons.analytics.codePoint: Icons.analytics,
    Icons.insights.codePoint: Icons.insights,
    Icons.auto_graph.codePoint: Icons.auto_graph,
    Icons.scale.codePoint: Icons.scale,
    Icons.print.codePoint: Icons.print,
    Icons.trending_up.codePoint: Icons.trending_up,
    Icons.savings.codePoint: Icons.savings,
    Icons.restore.codePoint: Icons.restore,
    Icons.info_outline.codePoint: Icons.info_outline,
    Icons.check_circle_outline.codePoint: Icons.check_circle_outline,
    Icons.business.codePoint: Icons.business,
    Icons.lock_clock.codePoint: Icons.lock_clock,
    Icons.card_giftcard.codePoint: Icons.card_giftcard,
    Icons.fact_check.codePoint: Icons.fact_check,
    Icons.history.codePoint: Icons.history,
    Icons.dashboard_customize.codePoint: Icons.dashboard_customize,
    Icons.extension.codePoint: Icons.extension,
  };

  static String _resolveColorHex(
    dynamic colorHexValue,
    dynamic legacyColorValue,
    String fallback,
  ) {
    if (colorHexValue is String && colorHexValue.trim().isNotEmpty) {
      return _normalizeColorString(colorHexValue);
    }

    if (legacyColorValue is int) {
      final legacyHex =
          '0x${legacyColorValue.toRadixString(16).padLeft(8, '0')}';
      return _normalizeColorString(legacyHex);
    }

    return _normalizeColorString(fallback);
  }

  static QuickActionItem? _legacyFallbackFor(String id) {
    switch (id) {
      case 'returns_list':
        return DefaultQuickActions.findById('return_invoice');
      default:
        return null;
    }
  }

  static String _normalizeColorString(String value) {
    final raw = value.trim();
    if (raw.isEmpty) {
      return '#FFD700';
    }

    if (raw.startsWith('#')) {
      if (raw.length == 7) {
        return raw.toUpperCase();
      }

      if (raw.length == 9) {
        return '#${raw.substring(3).toUpperCase()}';
      }

      final stripped = raw.substring(1);
      if (stripped.length >= 6) {
        return '#${stripped.substring(stripped.length - 6).toUpperCase()}';
      }
    }

    if (raw.startsWith('0x') || raw.startsWith('0X')) {
      final hex = raw.substring(2).padLeft(8, '0').toUpperCase();
      return '#${hex.substring(hex.length - 6)}';
    }

    if (raw.length == 6) {
      return '#${raw.toUpperCase()}';
    }

    if (raw.length == 8) {
      return '#${raw.substring(raw.length - 6).toUpperCase()}';
    }

    return '#FFD700';
  }
}

class DefaultQuickActions {
  static final List<QuickActionItem> _catalog = [
    // ─── المبيعات والمشتريات ────────────────────────────────────────
    QuickActionItem(
      id: 'sales_invoice',
      icon: Icons.point_of_sale,
      label: 'فاتورة بيع',
      route: 'sales_invoice',
      colorHex: '#2E7D32',
      isActive: true,
      order: 0,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'scrap_sales_invoice',
      icon: Icons.recycling_outlined,
      label: 'فاتورة بيع كسر',
      route: 'scrap_sales',
      colorHex: '#FB8C00',
      isActive: true,
      order: 1,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'purchase_invoice',
      icon: Icons.shopping_cart,
      label: 'فاتورة شراء',
      route: 'purchase_invoice',
      colorHex: '#9A7D0A',
      isActive: true,
      order: 2,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'scrap_purchase_invoice',
      icon: Icons.shopping_basket,
      label: 'فاتورة شراء كسر',
      route: 'scrap_purchase',
      colorHex: '#0288D1',
      isActive: true,
      order: 3,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'invoices_list',
      icon: Icons.receipt_long,
      label: 'جميع الفواتير',
      route: 'invoices_list',
      colorHex: '#546E7A',
      isActive: false,
      order: 4,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'return_sales',
      icon: Icons.keyboard_return,
      label: 'مرتجع بيع',
      route: 'return_sales',
      colorHex: '#E53935',
      isActive: true,
      order: 5,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'return_purchase',
      icon: Icons.undo,
      label: 'مرتجع شراء',
      route: 'return_purchase',
      colorHex: '#EF6C00',
      isActive: true,
      order: 6,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'return_purchase_supplier',
      icon: Icons.assignment_return,
      label: 'مرتجع شراء (مورد)',
      route: 'return_purchase_supplier',
      colorHex: '#FF7043',
      isActive: false,
      order: 7,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'return_invoice',
      icon: Icons.assignment_return_outlined,
      label: 'فاتورة مرتجع',
      route: 'return_invoice',
      colorHex: '#C62828',
      isActive: false,
      order: 8,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'add_customer',
      icon: Icons.person_add,
      label: 'عميل جديد',
      route: 'add_customer',
      colorHex: '#1976D2',
      isActive: true,
      order: 9,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'customers_list',
      icon: Icons.people,
      label: 'قائمة العملاء',
      route: 'customers_list',
      colorHex: '#0288D1',
      isActive: false,
      order: 10,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'suppliers_list',
      icon: Icons.store,
      label: 'قائمة الموردين',
      route: 'suppliers_list',
      colorHex: '#7B1FA2',
      isActive: false,
      order: 11,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'add_item',
      icon: Icons.add_box,
      label: 'صنف جديد',
      route: 'add_item',
      colorHex: '#D4AF37',
      isActive: true,
      order: 12,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'items_list',
      icon: Icons.inventory_2,
      label: 'قائمة الأصناف',
      route: 'items_list',
      colorHex: '#F57C00',
      isActive: false,
      order: 13,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'melting_renewal',
      icon: Icons.autorenew,
      label: 'التجديد والتكسير',
      route: 'melting_renewal',
      colorHex: '#FF6F00',
      isActive: true,
      order: 14,
      group: QuickActionGroup.sales,
    ),
    QuickActionItem(
      id: 'gold_reservation',
      icon: Icons.lock_clock,
      label: 'حجز ذهب خام',
      route: 'gold_reservation',
      colorHex: '#F9A825',
      isActive: false,
      order: 15,
      group: QuickActionGroup.sales,
    ),
    // ─── المحاسبة والتقارير ────────────────────────────────────────
    QuickActionItem(
      id: 'receipt_voucher',
      icon: Icons.south,
      label: 'سند قبض',
      route: 'receipt_voucher',
      colorHex: '#388E3C',
      isActive: false,
      order: 0,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'payment_voucher',
      icon: Icons.north,
      label: 'سند صرف',
      route: 'payment_voucher',
      colorHex: '#D32F2F',
      isActive: false,
      order: 1,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'vouchers_list',
      icon: Icons.receipt_long,
      label: 'قائمة السندات',
      route: 'vouchers_list',
      colorHex: '#5D4037',
      isActive: false,
      order: 2,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'journal_entry',
      icon: Icons.edit_note,
      label: 'إضافة قيد',
      route: 'journal_entry',
      colorHex: '#455A64',
      isActive: false,
      order: 3,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'journal_entries_list',
      icon: Icons.book,
      label: 'قيود اليومية',
      route: 'journal_entries_list',
      colorHex: '#5C6BC0',
      isActive: false,
      order: 4,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'accounts',
      icon: Icons.assessment,
      label: 'كشوفات الحسابات',
      route: 'accounts',
      colorHex: '#546E7A',
      isActive: false,
      order: 5,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'recurring_entries',
      icon: Icons.repeat,
      label: 'القيود الدورية',
      route: 'recurring_entries',
      colorHex: '#6A1B9A',
      isActive: false,
      order: 6,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'general_ledger',
      icon: Icons.menu_book,
      label: 'دفتر الأستاذ العام',
      route: 'general_ledger',
      colorHex: '#FFB300',
      isActive: false,
      order: 7,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'trial_balance',
      icon: Icons.account_balance_wallet,
      label: 'ميزان المراجعة',
      route: 'trial_balance',
      colorHex: '#8D6E63',
      isActive: false,
      order: 8,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'chart_of_accounts',
      icon: Icons.account_tree,
      label: 'دليل الحسابات',
      route: 'chart_of_accounts',
      colorHex: '#00897B',
      isActive: false,
      order: 9,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'weight_closing_execute',
      icon: Icons.scale,
      label: 'تنفيذ التسكير الوزني',
      route: 'weight_closing_execute',
      colorHex: '#C9A227',
      isActive: true,
      order: 10,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'shift_closing',
      icon: Icons.fact_check,
      label: 'إغلاق اليومية',
      route: 'shift_closing',
      colorHex: '#7CB342',
      isActive: false,
      order: 11,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'reports_center',
      icon: Icons.insights,
      label: 'مركز التقارير',
      route: 'reports_center',
      colorHex: '#00BFA5',
      isActive: true,
      order: 12,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'gold_price_history_report',
      icon: Icons.auto_graph,
      label: 'تقرير سعر الذهب',
      route: 'gold_price_history',
      colorHex: '#FFD700',
      isActive: false,
      order: 13,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'gold_position_report',
      icon: Icons.scale,
      label: 'تقرير مركز الذهب',
      route: 'gold_position',
      colorHex: '#FDD835',
      isActive: false,
      order: 14,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'payroll_report',
      icon: Icons.analytics,
      label: 'تقارير الرواتب',
      route: 'payroll_report',
      colorHex: '#512DA8',
      isActive: false,
      order: 15,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'gold_price',
      icon: Icons.trending_up,
      label: 'سعر الذهب',
      route: 'gold_price',
      colorHex: '#F9A825',
      isActive: false,
      order: 16,
      group: QuickActionGroup.accounting,
    ),
    // ─── الإدارة ────────────────────────────────────────────────────
    QuickActionItem(
      id: 'posting_management',
      icon: Icons.check_circle_outline,
      label: 'إدارة الترحيل',
      route: 'posting_management',
      colorHex: '#2E7D32',
      isActive: true,
      order: 0,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'printing_center',
      icon: Icons.print,
      label: 'مركز الطباعة',
      route: 'printing_center',
      colorHex: '#1976D2',
      isActive: true,
      order: 1,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'safe_boxes',
      icon: Icons.savings,
      label: 'إدارة الخزائن',
      route: 'safe_boxes',
      colorHex: '#FFA000',
      isActive: false,
      order: 2,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'employees',
      icon: Icons.badge,
      label: 'الموظفون',
      route: 'employees',
      colorHex: '#B8860B',
      isActive: false,
      order: 3,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'users',
      icon: Icons.manage_accounts,
      label: 'المستخدمون',
      route: 'users',
      colorHex: '#1565C0',
      isActive: false,
      order: 4,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'payroll',
      icon: Icons.payments_rounded,
      label: 'الرواتب',
      route: 'payroll',
      colorHex: '#2E7D32',
      isActive: false,
      order: 5,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'attendance',
      icon: Icons.event_available,
      label: 'الحضور والانصراف',
      route: 'attendance',
      colorHex: '#6A1B9A',
      isActive: false,
      order: 6,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'bonuses',
      icon: Icons.card_giftcard,
      label: 'المكافآت',
      route: 'bonuses',
      colorHex: '#546E7A',
      isActive: false,
      order: 7,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'offices',
      icon: Icons.business,
      label: 'مكاتب التسكير',
      route: 'offices',
      colorHex: '#B8860B',
      isActive: false,
      order: 8,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'branches_management',
      icon: Icons.account_tree,
      label: 'إدارة المكاتب والفروع',
      route: 'branches_management',
      colorHex: '#00897B',
      isActive: false,
      order: 9,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'audit_log',
      icon: Icons.history,
      label: 'سجل التدقيق',
      route: 'audit_log',
      colorHex: '#455A64',
      isActive: false,
      order: 10,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'admin_dashboard',
      icon: Icons.dashboard_customize,
      label: 'لوحة تحكم المدير',
      route: 'admin_dashboard',
      colorHex: '#D4AF37',
      isActive: false,
      order: 11,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'system_reset',
      icon: Icons.restore,
      label: 'إعادة تهيئة النظام',
      route: 'system_reset',
      colorHex: '#D84315',
      isActive: false,
      order: 12,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'printer_settings',
      icon: Icons.print,
      label: 'إعدادات الطابعة',
      route: 'printer_settings',
      colorHex: '#7E57C2',
      isActive: false,
      order: 13,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'about',
      icon: Icons.info_outline,
      label: 'حول التطبيق',
      route: 'about',
      colorHex: '#00838F',
      isActive: false,
      order: 14,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'clearing_settlement',
      icon: Icons.swap_horiz,
      label: 'تسوية المقاصة',
      route: 'clearing_settlement',
      colorHex: '#00897B',
      isActive: false,
      order: 15,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'import_documents',
      icon: Icons.upload_file,
      label: 'استيراد Excel',
      route: 'import_documents',
      colorHex: '#2E7D32',
      isActive: false,
      order: 16,
      group: QuickActionGroup.admin,
    ),
    QuickActionItem(
      id: 'reports_center',
      icon: Icons.insights,
      label: 'مركز التقارير',
      route: 'reports_center',
      colorHex: '#3949AB',
      isActive: false,
      order: 12,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'gold_price_history',
      icon: Icons.auto_graph,
      label: 'سعر الذهب - تاريخي',
      route: 'gold_price_history',
      colorHex: '#F57F17',
      isActive: false,
      order: 13,
      group: QuickActionGroup.accounting,
    ),
    QuickActionItem(
      id: 'posting_management',
      icon: Icons.check_circle_outline,
      label: 'اعتماد الترحيل',
      route: 'posting_management',
      colorHex: '#00695C',
      isActive: false,
      order: 0,
      group: QuickActionGroup.admin,
    ),
  ];

  static List<QuickActionItem> getAll() =>
      _catalog.map((item) => item.copyWith()).toList();

  static QuickActionItem? findById(String id) {
    try {
      return _catalog.firstWhere((item) => item.id == id).copyWith();
    } catch (_) {
      return null;
    }
  }

  static List<QuickActionItem> getDefaultActive() {
    // Default quick access buttons (used for first-run and reset-to-defaults).
    // Keep this list minimal and in the exact intended order.
    const defaultIds = <String>[
      'sales_invoice',
      'scrap_purchase_invoice',
      'scrap_sales_invoice',
      'purchase_invoice',
      'vouchers_list',
      'journal_entries_list',
      'accounts',
      'reports_center',
      'posting_management',
    ];

    final List<QuickActionItem> defaults = [];
    for (int i = 0; i < defaultIds.length; i++) {
      final item = findById(defaultIds[i]);
      if (item == null) continue;
      defaults.add(item.copyWith(isActive: true, order: i));
    }
    return defaults;
  }

  static List<QuickActionItem> catalogExcluding(Set<String> ids) {
    return _catalog
        .where((item) => !ids.contains(item.id))
        .map((item) => item.copyWith())
        .toList()
      ..sort((a, b) => a.label.compareTo(b.label));
  }

  static List<QuickActionItem> catalogForGroup(QuickActionGroup group) {
    return _catalog
        .where((item) => item.group == group)
        .map((item) => item.copyWith())
        .toList()
      ..sort((a, b) => a.label.compareTo(b.label));
  }
}
