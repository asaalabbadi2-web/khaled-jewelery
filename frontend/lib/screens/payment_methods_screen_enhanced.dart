import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../utils/payment_fee.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/app_table.dart';
import '../widgets/payment_method_form.dart';

/// The payment methods (the owner, 24 Nov 2026: «شاشة وسائل الدفع
/// وديالوجاتها تحتاج تطوير من حيث الشكل، الألوان والتباين ودعم الشاشات
/// الصغيرة والكبيرة»): on a wide screen a table, a row a method -- what it
/// takes, its plans, its settlement, its invoices, side by side; on a phone a
/// compact card each. Every color the theme's, in both modes; its order the
/// invoice screens' (PAY-ORDER-1); adding and editing in [showPaymentMethodForm].
class PaymentMethodsScreenEnhanced extends StatefulWidget {
  /// The server; a test hands its own.
  final ApiService? apiService;

  const PaymentMethodsScreenEnhanced({super.key, this.apiService});

  @override
  State<PaymentMethodsScreenEnhanced> createState() => _PaymentMethodsScreenEnhancedState();
}

/// A wide screen: a table from here, cards below it.
const double paymentMethodsTableMinWidth = 900;

class _PaymentMethodsScreenEnhancedState extends State<PaymentMethodsScreenEnhanced> {
  late final ApiService apiService = widget.apiService ?? ApiService();
  List<Map<String, dynamic>> _paymentMethods = [];
  List<Map<String, dynamic>> _paymentTypes = [];
  List<Map<String, dynamic>> _invoiceTypeOptions = [];
  List<String> _invoiceTypeDefaultSelection = [];
  List<SafeBoxModel> _availableSafeBoxes = [];
  List<Map<String, dynamic>> _accounts = [];
  bool _isLoading = true;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  Future<void> _fetchData() async {
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final methodsRaw = await apiService.getPaymentMethods();
      final types = await apiService.getPaymentTypes();
      List<SafeBoxModel> safeBoxes = <SafeBoxModel>[];
      try {
        safeBoxes = await apiService.getSafeBoxes(
          isActive: true,
          includeAccount: false,
          includeBalance: false,
        );
      } catch (_) {
        safeBoxes = <SafeBoxModel>[];
      }
      Map<String, dynamic>? invoiceTypesPayload;
      try {
        invoiceTypesPayload = await apiService.getPaymentInvoiceTypeOptions();
      } catch (_) {
        invoiceTypesPayload = null;
      }

      const fallbackPaymentTypes = [
        {'code': 'cash', 'name_ar': 'نقدي', 'icon': '💵'},
        {'code': 'mada', 'name_ar': 'بطاقة مدى', 'icon': '💳'},
        {'code': 'visa', 'name_ar': 'بطاقة فيزا', 'icon': '💳'},
        {'code': 'mastercard', 'name_ar': 'بطاقة ماستركارد', 'icon': '💳'},
        {'code': 'stc_pay', 'name_ar': 'STC Pay', 'icon': '📱'},
        {'code': 'apple_pay', 'name_ar': 'Apple Pay', 'icon': '📱'},
        {'code': 'tabby', 'name_ar': 'تابي', 'icon': '🛍️'},
        {'code': 'tamara', 'name_ar': 'تمارا', 'icon': '🛍️'},
        {'code': 'bank_transfer', 'name_ar': 'تحويل بنكي', 'icon': '🏦'},
      ];

      const fallbackInvoiceTypes = [
        {
          'value': 'بيع',
          'name_ar': 'فاتورة بيع',
          'category': 'pos',
          'description': 'بيع ذهب جديد للعميل',
        },
        {
          'value': 'شراء من عميل',
          'name_ar': 'شراء كسر',
          'category': 'pos',
          'description': 'شراء ذهب كسر من العميل',
        },
        {
          'value': 'مرتجع بيع',
          'name_ar': 'مرتجع بيع',
          'category': 'pos',
          'description': 'استرجاع فاتورة بيع من العميل',
        },
        {
          'value': 'مرتجع شراء',
          'name_ar': 'مرتجع شراء كسر',
          'category': 'pos',
          'description': 'استرجاع مشتريات الكسر من العميل',
        },
        {
          'value': 'شراء',
          'name_ar': 'شراء جديد',
          'category': 'accounting',
          'description': 'شراء ذهب جديد من المورد',
        },
        {
          'value': 'مرتجع شراء (مورد)',
          'name_ar': 'مرتجع شراء جديد',
          'category': 'accounting',
          'description': 'استرجاع مشتريات من المورد',
        },
      ];

      final existingTypeCodes = types
          .whereType<Map<String, dynamic>>()
          .map((type) => type['code']?.toString())
          .whereType<String>()
          .toSet();

      final ensuredTypes = List<Map<String, dynamic>>.from(
        types.whereType<Map<String, dynamic>>(),
      );

      for (final fallback in fallbackPaymentTypes) {
        if (!existingTypeCodes.contains(fallback['code'])) {
          ensuredTypes.add(fallback);
        }
      }

      // Ensure dropdown items are unique by code (Dropdown asserts on duplicates).
      final dedupedTypesByCode = <String, Map<String, dynamic>>{};
      for (final type in ensuredTypes) {
        final code = type['code']?.toString();
        if (code == null || code.trim().isEmpty) continue;
        dedupedTypesByCode.putIfAbsent(code, () => type);
      }

      final invoiceOptions = (invoiceTypesPayload?['options'] is List)
          ? (invoiceTypesPayload?['options'] as List)
                .whereType<Map<String, dynamic>>()
                .map((option) => Map<String, dynamic>.from(option))
                .toList()
          : List<Map<String, dynamic>>.from(fallbackInvoiceTypes);

      if (invoiceOptions.isEmpty) {
        invoiceOptions.addAll(
          fallbackInvoiceTypes.map(
            (option) => Map<String, dynamic>.from(option),
          ),
        );
      }

      final defaultInvoiceSelection =
          (invoiceTypesPayload?['default_selection'] is List)
          ? (invoiceTypesPayload?['default_selection'] as List)
                .map((entry) => entry.toString())
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList()
          : invoiceOptions
                .map((option) => option['value']?.toString() ?? '')
                .where((value) => value.isNotEmpty)
                .toSet()
                .toList();

      final paymentMethods = methodsRaw
          .whereType<Map<String, dynamic>>()
          .map((method) => Map<String, dynamic>.from(method))
          .toList();

      List<Map<String, dynamic>> accounts = [];
      try {
        final rawAccounts = await apiService.getAccounts();
        accounts = rawAccounts
            .whereType<Map<String, dynamic>>()
            .where((a) {
              final hasChildren =
                  (a['sub_accounts'] as List?)?.isNotEmpty == true;
              return !hasChildren; // detail accounts only
            })
            .map((a) => Map<String, dynamic>.from(a))
            .toList();
      } catch (_) {
        accounts = [];
      }

      if (!mounted) return;
      setState(() {
        _paymentMethods = paymentMethods;
        _paymentTypes = dedupedTypesByCode.values.toList();
        _invoiceTypeOptions = invoiceOptions;
        _invoiceTypeDefaultSelection = defaultInvoiceSelection;
        _availableSafeBoxes = safeBoxes;
        _accounts = accounts;
        _isLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = error;
      });
    }
  }


  Future<void> _openForm({Map<String, dynamic>? editing}) async {
    final saved = await showPaymentMethodForm(
      context,
      api: apiService,
      editingMethod: editing,
      paymentTypes: _paymentTypes,
      invoiceTypeOptions: _invoiceTypeOptions,
      invoiceTypeDefaultSelection: _invoiceTypeDefaultSelection,
      safeBoxes: _availableSafeBoxes,
      accounts: _accounts,
    );
    if (saved == true && mounted) {
      AppFeedback.success(context, editing == null ? 'أُضيفت وسيلة الدفع' : 'حُفظت وسيلة الدفع');
      _fetchData();
    }
  }

  Future<void> _deletePaymentMethod(Map<String, dynamic> method) async {
    final cs = Theme.of(context).colorScheme;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: cs.error),
        title: const Text('حذف وسيلة الدفع'),
        content: Text('تُحذف «${method['name'] ?? ''}». إن كانت عليها دفعات يرفض الخادم حذفها؛ عطّلها بدل ذلك.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(
            key: const Key('pm-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    try {
      final result = await apiService.deletePaymentMethod(method['id'] as int);
      if (!mounted) return;
      final said = '${result['message'] ?? ''}'.trim();
      AppFeedback.success(context, said.isNotEmpty ? said : 'حُذفت وسيلة الدفع');
      _fetchData();
    } catch (error) {
      if (mounted) AppFeedback.error(context, error, title: 'لم تُحذف وسيلة الدفع');
    }
  }

  /// Moves a method one place and saves the whole order; on failure the
  /// list goes back as it was and says so.
  Future<void> _moveMethod(int index, int delta) async {
    final target = index + delta;
    if (target < 0 || target >= _paymentMethods.length) return;
    final before = List<Map<String, dynamic>>.from(_paymentMethods);
    setState(() {
      final moved = _paymentMethods.removeAt(index);
      _paymentMethods.insert(target, moved);
      for (var i = 0; i < _paymentMethods.length; i++) {
        _paymentMethods[i]['display_order'] = i + 1;
      }
    });
    try {
      await apiService.updatePaymentMethodsOrder(_paymentMethods);
    } catch (error) {
      if (!mounted) return;
      setState(() => _paymentMethods = before);
      AppFeedback.error(context, error, title: 'لم يُحفظ الترتيب');
    }
  }

  // ── what a method says ────────────────────────────────────────────────

  static double _num(Object? v) => v is num ? v.toDouble() : double.tryParse('${v ?? ''}') ?? 0.0;

  static String _n(double v) => v == v.roundToDouble() ? '${v.toInt()}' : '$v';

  /// «0.8%», «6.99% + 1.5 لكل عملية», «—» -- what it takes an order.
  String _commissionLine(Map<String, dynamic> m) {
    final rate = _num(m['commission_rate']);
    final fixed = _num(m['commission_fixed_amount']);
    final plans = PaymentFee.plansOf(m);
    final rates = plans.isEmpty ? <double>[rate] : (plans.values.toSet().toList()..sort());
    final pct = ltrIsolate(rates.length == 1 ? '${_n(rates.first)}%' : '${_n(rates.first)}–${_n(rates.last)}%');
    if (rates.every((r) => r == 0) && fixed == 0) return '—';
    return fixed > 0 ? '$pct + ${ltrIsolate(_n(fixed))} لكل عملية' : pct;
  }

  /// The plans by their rate: «2، 3، 4 دفعات: 6.99%» -- the noun as the last
  /// number takes it (PaymentFee.installmentsLabel).
  List<String> _planLines(Map<String, dynamic> m) {
    final byRate = <double, List<int>>{};
    PaymentFee.plansOf(m).forEach((n, r) => byRate.putIfAbsent(r, () => []).add(n));
    String counted(List<int> ns) {
      final last = PaymentFee.installmentsLabel(ns.last);
      if (ns.length == 1) return last;
      final lead = RegExp(r'^\d+ ');
      return lead.hasMatch(last) ? last.replaceFirst(lead, '${ns.join('، ')} ') : '${ns.join('، ')} دفعات';
    }
    return [for (final e in byRate.entries) '${counted(e.value)}: ${ltrIsolate('${_n(e.key)}%')}'];
  }

  String? _depositFeeLine(Map<String, dynamic> m) {
    final fee = _num(m['deposit_fixed_fee']);
    return fee > 0 ? '${ltrIsolate(_n(fee))} لكل إيداع' : null;
  }

  String _settlementLine(Map<String, dynamic> m) {
    if (m['auto_settlement_enabled'] != true) return 'يدوية';
    final s = '${m['schedule_summary'] ?? ''}'.trim();
    return s.isEmpty ? 'تلقائية' : s;
  }

  String _invoicesLine(Map<String, dynamic> m) {
    final raw = m['applicable_invoice_types'];
    final types = raw is List ? [for (final v in raw) if ('${v ?? ''}'.isNotEmpty) '$v'] : <String>[];
    if (types.isEmpty) return 'كل الأنواع';
    String label(String v) {
      for (final o in _invoiceTypeOptions) {
        if ('${o['value']}' == v) return '${o['name_ar'] ?? o['label'] ?? v}';
      }
      return v;
    }
    return types.map(label).join('، ');
  }

  /// The safe it takes its payments into -- said only when its name is not
  /// the method's own («مدى» into «مدى» says nothing).
  String? _safeName(Map<String, dynamic> m) {
    final box = m['default_safe_box'];
    final name = box is Map ? '${box['name'] ?? ''}'.trim() : '';
    if (name.isEmpty || name == '${m['name'] ?? ''}'.trim()) return null;
    return 'الخزينة: $name';
  }

  // ── the screen ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('وسائل الدفع'),
        actions: [
          IconButton(onPressed: _fetchData, icon: const Icon(Icons.refresh), tooltip: 'تحديث'),
          LayoutBuilder(builder: (context, _) {
            final wide = MediaQuery.sizeOf(context).width >= 600;
            return Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: wide
                  // Tonal: the light bar is the primary's own gold.
                  ? FilledButton.tonalIcon(
                      key: const Key('pm-add'),
                      onPressed: () => _openForm(),
                      icon: const Icon(Icons.add),
                      label: const Text('إضافة وسيلة دفع'),
                    )
                  : IconButton.filledTonal(
                      key: const Key('pm-add'),
                      tooltip: 'إضافة وسيلة دفع',
                      onPressed: () => _openForm(),
                      icon: const Icon(Icons.add),
                    ),
            );
          }),
        ],
      ),
      body: _isLoading
          ? const AppLoadingView(summaryBlocks: 3, rows: 5)
          : _loadError != null
          ? AppErrorView(title: 'تعذّر تحميل وسائل الدفع', error: _loadError!, onRetry: _fetchData)
          : _paymentMethods.isEmpty
          ? AppEmptyView(
              title: 'لا توجد وسائل دفع',
              hint: 'أضف أول وسيلة دفع لتظهر في الفواتير.',
              icon: Icons.payments_outlined,
              actionLabel: 'إضافة وسيلة دفع',
              actionIcon: Icons.add,
              onAction: () => _openForm(),
            )
          : LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= paymentMethodsTableMinWidth;
                return Column(
                  children: [
                    _summary(wide),
                    Expanded(child: wide ? _table() : _cards()),
                  ],
                );
              },
            ),
    );
  }

  Widget _summary(bool wide) {
    final tones = AppSemanticColors.of(context);
    final active = _paymentMethods.where((m) => m['is_active'] == true).length;
    final auto = _paymentMethods.where((m) => m['auto_settlement_enabled'] == true).length;
    final confirmed = _paymentMethods.where((m) => m['deposit_confirmation_required'] == true).length;
    final items = [
      ('الوسائل', '${_paymentMethods.length}', Icons.layers_outlined, tones.sectionSlate),
      ('النشطة', '$active', Icons.check_circle_outline, tones.ready),
      ('تسوية تلقائية', '$auto', Icons.event_repeat_outlined, tones.info),
      ('يُؤكَّد إيداعها', '$confirmed', Icons.fact_check_outlined, tones.gold),
    ];
    return Padding(
      key: const Key('pm-summary'),
      padding: EdgeInsets.fromLTRB(16, 12, 16, wide ? 12 : 8),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final (label, value, icon, tone) in items)
            Container(
              width: wide ? 200 : null,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(12)),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 18, color: tone.onContainer),
                  const SizedBox(width: 8),
                  Text(label, style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tone.onContainer)),
                  const SizedBox(width: 8),
                  Text(value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: tone.onContainer,
                            fontWeight: FontWeight.w800,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          )),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _typeBadge(Map<String, dynamic> m, {double size = 40}) {
    final tone = paymentTypeTone(context, '${m['payment_type'] ?? ''}');
    final active = m['is_active'] == true;
    final cs = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: active ? tone.container : cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(size / 3.5),
      ),
      child: Icon(paymentTypeIcon('${m['payment_type'] ?? ''}'),
          size: size * 0.55, color: active ? tone.onContainer : cs.onSurfaceVariant),
    );
  }

  Widget _status(bool active) {
    final tones = AppSemanticColors.of(context);
    final tone = active ? tones.ready : tones.blocked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(999)),
      child: Text(active ? 'نشطة' : 'معطّلة',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700)),
    );
  }

  Widget _tag(String text, {IconData? icon, Key? key}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      key: key,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 14, color: cs.onSurfaceVariant), const SizedBox(width: 4)],
          Flexible(
            child: Text(text,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurface)),
          ),
        ],
      ),
    );
  }

  Widget _orderButtons(int index, Map<String, dynamic> m) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconButton(
        key: Key('order-up-${m['id']}'),
        tooltip: 'أعلى',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.arrow_upward),
        onPressed: index == 0 ? null : () => _moveMethod(index, -1),
      ),
      IconButton(
        key: Key('order-down-${m['id']}'),
        tooltip: 'أسفل',
        visualDensity: VisualDensity.compact,
        icon: const Icon(Icons.arrow_downward),
        onPressed: index == _paymentMethods.length - 1 ? null : () => _moveMethod(index, 1),
      ),
    ],
  );

  Widget _menu(Map<String, dynamic> m) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      key: Key('pm-menu-${m['id']}'),
      tooltip: 'المزيد',
      icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant),
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('تعديل'), contentPadding: EdgeInsets.zero),
        ),
        PopupMenuItem(
          value: 'delete',
          child: ListTile(
            leading: Icon(Icons.delete_outline, color: cs.error),
            title: Text('حذف', style: TextStyle(color: cs.error)),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ],
      onSelected: (v) => v == 'edit' ? _openForm(editing: m) : _deletePaymentMethod(m),
    );
  }

  // ── a wide screen: the table ──────────────────────────────────────────

  static const _columns = {
    'order': AppTableColumn(140),
    'name': AppTableColumn(220, grow: 2),
    'fee': AppTableColumn(190, grow: 1),
    'plans': AppTableColumn(200, grow: 2),
    'settlement': AppTableColumn(220, grow: 2),
    'invoices': AppTableColumn(160, grow: 1),
    'status': AppTableColumn(96),
    'actions': AppTableColumn(104),
  };

  Widget _table() {
    return AppTableFrame(
      columns: _columns,
      onRefresh: _fetchData,
      rowCount: _paymentMethods.length,
      header: (widths) {
        final theme = Theme.of(context);
        final style = theme.textTheme.labelLarge?.copyWith(
          fontWeight: FontWeight.w800,
          color: theme.colorScheme.onSurfaceVariant,
        );
        Widget cell(String key, String label) => SizedBox(
          width: widths[key],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(label, style: style, overflow: TextOverflow.ellipsis),
          ),
        );
        return Container(
          height: 48,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHigh,
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
          ),
          child: Row(children: [
            cell('order', 'الترتيب'),
            cell('name', 'الوسيلة'),
            cell('fee', 'العمولة'),
            cell('plans', 'الخطط'),
            cell('settlement', 'التسوية'),
            cell('invoices', 'الفواتير'),
            cell('status', 'الحالة'),
            cell('actions', ''),
          ]),
        );
      },
      row: (context, i, widths) {
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final m = _paymentMethods[i];
        final muted = cs.onSurfaceVariant;
        Widget pad(String key, Widget child) => SizedBox(
          width: widths[key],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Align(alignment: AlignmentDirectional.centerStart, child: child),
          ),
        );
        final plans = _planLines(m);
        final depositFee = _depositFeeLine(m);
        return Material(
          color: i.isOdd ? cs.surfaceContainerLowest : cs.surface,
          child: InkWell(
            key: Key('pm-row-${m['id']}'),
            onTap: () => _openForm(editing: m),
            child: Container(
              constraints: const BoxConstraints(minHeight: 64),
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6))),
              ),
              child: Row(
                children: [
                  pad('order', Row(mainAxisSize: MainAxisSize.min, children: [
                    Text('${i + 1}', key: Key('order-place-${m['id']}'),
                        style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)),
                    _orderButtons(i, m),
                  ])),
                  pad('name', Row(children: [
                    _typeBadge(m),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${m['name'] ?? '—'}', maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w700)),
                          if (_safeName(m) != null)
                            Text(_safeName(m)!, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                        ],
                      ),
                    ),
                  ])),
                  pad('fee', Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_commissionLine(m), style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                      if (depositFee != null)
                        Text(depositFee, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                    ],
                  )),
                  pad('plans', plans.isEmpty
                      ? Text('—', style: TextStyle(color: muted))
                      : Wrap(spacing: 6, runSpacing: 6, children: [for (final p in plans) _tag(p)])),
                  pad('settlement', Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_settlementLine(m), maxLines: 2, overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall),
                      if (m['deposit_confirmation_required'] == true) ...[
                        const SizedBox(height: 4),
                        _tag('يُؤكَّد إيداعها', icon: Icons.fact_check_outlined),
                      ],
                    ],
                  )),
                  pad('invoices', Text(_invoicesLine(m), maxLines: 2, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: muted))),
                  pad('status', _status(m['is_active'] == true)),
                  SizedBox(
                    width: widths['actions'],
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        IconButton(
                          key: Key('pm-edit-${m['id']}'),
                          tooltip: 'تعديل',
                          icon: Icon(Icons.edit_outlined, color: cs.primary),
                          onPressed: () => _openForm(editing: m),
                        ),
                        _menu(m),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ── a phone: the cards ────────────────────────────────────────────────

  Widget _cards() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return RefreshIndicator(
      onRefresh: _fetchData,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: _paymentMethods.length,
        separatorBuilder: (_, _) => const SizedBox(height: 10),
        itemBuilder: (context, i) {
          final m = _paymentMethods[i];
          final plans = _planLines(m);
          final depositFee = _depositFeeLine(m);
          Widget line(IconData icon, String label, Widget value) => Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, size: 16, color: cs.onSurfaceVariant),
                const SizedBox(width: 6),
                SizedBox(
                  width: 64,
                  child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                ),
                Expanded(child: value),
              ],
            ),
          );
          return Material(
            key: Key('pm-card-${m['id']}'),
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: cs.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openForm(editing: m),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        _typeBadge(m, size: 36),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${m['name'] ?? '—'}', maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                              Text('الترتيب ${i + 1}',
                                  style: theme.textTheme.labelSmall?.copyWith(color: cs.onSurfaceVariant)),
                            ],
                          ),
                        ),
                        _status(m['is_active'] == true),
                        _orderButtons(i, m),
                        _menu(m),
                      ],
                    ),
                    line(Icons.percent, 'العمولة', Text(
                      [_commissionLine(m), if (depositFee != null) depositFee].join(' · '),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    )),
                    if (plans.isNotEmpty)
                      line(Icons.view_week_outlined, 'الخطط',
                          Wrap(spacing: 6, runSpacing: 6, children: [for (final p in plans) _tag(p)])),
                    line(Icons.event_repeat_outlined, 'التسوية', Text(
                      [_settlementLine(m), if (m['deposit_confirmation_required'] == true) 'يُؤكَّد إيداعها'].join(' · '),
                      style: theme.textTheme.bodySmall,
                    )),
                    line(Icons.receipt_long_outlined, 'الفواتير',
                        Text(_invoicesLine(m), style: theme.textTheme.bodySmall)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
