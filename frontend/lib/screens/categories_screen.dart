import 'package:flutter/material.dart';

import '../api_service.dart';
import '../models/category_model.dart';
import '../theme/app_semantic_colors.dart';
import '../utils/bidi.dart';
import '../widgets/app_feedback.dart';
import '../widgets/app_state_views.dart';
import '../widgets/app_table.dart';
import 'item_sections_screen.dart';
import 'size_systems_screen.dart';

/// The categories, a screen of their own (the owner, 24 Nov 2026: «شاشة إدارة
/// التصنيفات برأيك ألا تحتاج شاشة وليس ديالوج؟»). They were a list in a 500-px
/// dialog -- 44 of them on the 24 Nov copy, no search, no filter -- each edit a
/// dialog upon it. Now a table on a wide screen (karat, section, tracking,
/// sizes, wage, items side by side), cards on a phone; searched and filtered;
/// edited beside the table on a wide screen, on a page of its own on a phone.
/// Every rule the server's (services/categories, pieces, item_sections,
/// size_systems); every color the theme's.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key, required this.api, this.onChanged});

  final ApiService api;

  /// The screen it was opened from reloads its choices.
  final VoidCallback? onChanged;

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

/// A wide screen: the table and the form beside it, from here.
const double categoriesTableFrom = 1000;

const _karats = [18, 21, 22, 24];

enum _Status { all, active, stopped }

/// Items said as Arabic counts them: بلا أصناف، صنف واحد، صنفان، 3–10 أصناف،
/// 11 فأكثر صنفًا.
String itemsLabel(int n) => switch (n) {
  0 => 'بلا أصناف',
  1 => 'صنف واحد',
  2 => 'صنفان',
  >= 3 && <= 10 => '$n أصناف',
  _ => '$n صنفًا',
};

class _CategoriesScreenState extends State<CategoriesScreen> {
  List<Category>? _all;
  Object? _error;
  List<Map<String, dynamic>> _sections = [];
  List<Map<String, dynamic>>? _systems;

  final _search = TextEditingController();
  int? _karat;
  int? _sectionFilter; // -1: no section
  String? _trackingFilter;
  _Status _statusFilter = _Status.all;

  /// The form beside the table: a category edited, or a new one (null id).
  Category? _editing;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final rows = await widget.api.getCategories(includeInactive: true);
      List<Map<String, dynamic>> sections = _sections;
      List<Map<String, dynamic>>? systems = _systems;
      try {
        final s = await widget.api.itemSections();
        sections = [for (final x in (s['sections'] as List? ?? const [])) Map<String, dynamic>.from(x as Map)];
      } catch (_) {}
      try {
        systems = await widget.api.getSizeSystems();
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _all = [for (final r in rows) Category.fromJson(r as Map<String, dynamic>)];
        _sections = sections;
        _systems = systems;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  void _changed() {
    widget.onChanged?.call();
    _load();
  }

  // ── what is shown ─────────────────────────────────────────────────────

  List<Category> get _shown {
    final q = _search.text.trim();
    return [
      for (final c in _all ?? const <Category>[])
        if ((q.isEmpty || c.name.contains(q) || (c.description ?? '').contains(q)) &&
            (_karat == null || int.tryParse(c.karat ?? '') == _karat) &&
            (_sectionFilter == null ||
                (_sectionFilter == -1 ? c.sectionId == null : c.sectionId == _sectionFilter)) &&
            (_trackingFilter == null || c.tracking == _trackingFilter) &&
            (_statusFilter == _Status.all || (_statusFilter == _Status.active) == c.isActive))
          c,
    ];
  }

  String _systemName(int? id) {
    if (id == null) return '—';
    for (final s in _systems ?? const <Map<String, dynamic>>[]) {
      if (s['id'] == id) return '${s['name']}';
    }
    return '—';
  }

  static String _wage(double? w) {
    if (w == null || w <= 0) return '—';
    return ltrIsolate(w == w.roundToDouble() ? '${w.toInt()}' : '$w');
  }

  // ── acting ────────────────────────────────────────────────────────────

  Future<void> _openForm(Category? category, {required bool wide}) async {
    if (wide) {
      setState(() {
        _editing = category;
        _adding = category == null;
      });
      return;
    }
    final saved = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => _CategoryFormPage(
        api: widget.api,
        category: category,
        sections: _sections,
        systems: _systems,
      ),
    ));
    if (saved == true && mounted) {
      AppFeedback.success(context, category == null ? 'أُضيف التصنيف' : 'حُفظ التصنيف');
      _changed();
    }
  }

  void _closePanel() => setState(() {
    _editing = null;
    _adding = false;
  });

  Future<void> _toggleActive(Category c) async {
    try {
      await widget.api.updateCategory(c.id!, {'is_active': !c.isActive});
      if (!mounted) return;
      AppFeedback.success(context, c.isActive ? 'أُوقف «${c.name}»' : 'أُعيد تفعيل «${c.name}»');
      _changed();
    } catch (error) {
      if (mounted) AppFeedback.error(context, error, title: 'لم تتغيّر حالة التصنيف');
    }
  }

  Future<void> _delete(Category c) async {
    final cs = Theme.of(context).colorScheme;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(Icons.delete_outline, color: cs.error),
        title: Text('حذف «${c.name}»'),
        content: Text((c.itemsCount ?? 0) > 0
            ? 'عليه ${itemsLabel(c.itemsCount!)}. التصنيف المستعمل لا يُحذف، ويُوقَف بدلًا من ذلك.'
            : 'لا أصناف عليه. يُحذف إن لم يكن في أي فاتورة.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('إلغاء')),
          FilledButton(
            key: const Key('category-delete-confirm'),
            style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    try {
      await widget.api.deleteCategory(c.id!);
      if (!mounted) return;
      AppFeedback.success(context, 'حُذف «${c.name}»');
      if (_editing?.id == c.id) _closePanel();
      _changed();
    } catch (error) {
      if (!mounted) return;
      // A used category is stopped instead (the server: «أوقفه بدل حذفه»).
      AppFeedback.warning(
        context,
        AppFeedback.messageOf(error),
        action: c.isActive ? (label: 'أوقفه', onPressed: () => _toggleActive(c)) : null,
      );
    }
  }

  // ── the screen ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= categoriesTableFrom;
    return Scaffold(
      appBar: AppBar(
        title: const Text('التصنيفات'),
        actions: [
          IconButton(
            key: const Key('categories-sections'),
            tooltip: 'الأقسام',
            icon: const Icon(Icons.account_tree_outlined),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => ItemSectionsScreen(api: widget.api)))
                .then((_) => _changed()),
          ),
          IconButton(
            key: const Key('categories-size-systems'),
            tooltip: 'أنظمة المقاسات',
            icon: const Icon(Icons.straighten),
            onPressed: () => Navigator.of(context)
                .push(MaterialPageRoute<void>(builder: (_) => SizeSystemsScreen(api: widget.api)))
                .then((_) => _load()),
          ),
          IconButton(tooltip: 'تحديث', icon: const Icon(Icons.refresh), onPressed: _load),
          Padding(
            padding: const EdgeInsetsDirectional.only(end: 8),
            child: width >= 600
                ? FilledButton.tonalIcon(
                    key: const Key('category-add'),
                    onPressed: () => _openForm(null, wide: wide),
                    icon: const Icon(Icons.add),
                    label: const Text('إضافة تصنيف'),
                  )
                : IconButton.filledTonal(
                    key: const Key('category-add'),
                    tooltip: 'إضافة تصنيف',
                    onPressed: () => _openForm(null, wide: wide),
                    icon: const Icon(Icons.add),
                  ),
          ),
        ],
      ),
      body: _all == null && _error != null
          ? AppErrorView(title: 'تعذّر تحميل التصنيفات', error: _error!, onRetry: _load)
          : _all == null
          ? const AppLoadingView(summaryBlocks: 0, rows: 8)
          : Column(
              children: [
                _filters(wide),
                Expanded(
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(child: _listOrEmpty(wide)),
                            if (_adding || _editing != null) ...[
                              VerticalDivider(width: 1, color: Theme.of(context).colorScheme.outlineVariant),
                              SizedBox(
                                width: 420,
                                child: _CategoryForm(
                                  key: ValueKey(_editing?.id ?? 'new'),
                                  api: widget.api,
                                  category: _editing,
                                  sections: _sections,
                                  systems: _systems,
                                  onCancel: _closePanel,
                                  onSaved: () {
                                    AppFeedback.success(context, _adding ? 'أُضيف التصنيف' : 'حُفظ التصنيف');
                                    _closePanel();
                                    _changed();
                                  },
                                ),
                              ),
                            ],
                          ],
                        )
                      : _listOrEmpty(wide),
                ),
              ],
            ),
    );
  }

  Widget _listOrEmpty(bool wide) {
    final shown = _shown;
    if ((_all ?? const []).isEmpty) {
      return AppEmptyView(
        title: 'لا توجد تصنيفات',
        hint: 'أضف أول تصنيف: اسمه وعياره.',
        icon: Icons.category_outlined,
        actionLabel: 'إضافة تصنيف',
        actionIcon: Icons.add,
        onAction: () => _openForm(null, wide: wide),
      );
    }
    if (shown.isEmpty) {
      return const AppEmptyView(title: 'لا تصنيف يطابق البحث', icon: Icons.search_off);
    }
    return wide ? _table(shown) : _cards(shown);
  }

  Widget _filters(bool wide) {
    final theme = Theme.of(context);
    final all = _all ?? const <Category>[];
    final karatCount = {for (final k in _karats) k: all.where((c) => int.tryParse(c.karat ?? '') == k).length};
    final search = TextField(
      key: const Key('categories-search'),
      controller: _search,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'بحث باسم التصنيف أو وصفه',
        prefixIcon: const Icon(Icons.search),
        suffixIcon: _search.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'مسح',
                icon: const Icon(Icons.close),
                onPressed: () => setState(_search.clear),
              ),
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
    final chips = Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final k in _karats)
          if (karatCount[k]! > 0)
            FilterChip(
              key: Key('categories-karat-$k'),
              selected: _karat == k,
              label: Text('عيار $k (${karatCount[k]})'),
              onSelected: (on) => setState(() => _karat = on ? k : null),
            ),
        _menuChip<int?>(
          key: const Key('categories-section-filter'),
          label: _sectionFilter == null
              ? 'كل الأقسام'
              : _sectionFilter == -1
              ? 'بلا قسم'
              : '${_sections.firstWhere((s) => s['id'] == _sectionFilter, orElse: () => {'name': '—'})['name']}',
          active: _sectionFilter != null,
          items: [
            (null, 'كل الأقسام'),
            (-1, 'بلا قسم'),
            for (final s in _sections) (s['id'] as int, '${s['name']}'),
          ],
          onPick: (v) => setState(() => _sectionFilter = v),
        ),
        _menuChip<String?>(
          key: const Key('categories-tracking-filter'),
          label: switch (_trackingFilter) {
            'weight' => 'بالوزن',
            'piece' => 'بالقطعة',
            _ => 'كل طرق التتبّع',
          },
          active: _trackingFilter != null,
          items: const [(null, 'كل طرق التتبّع'), ('weight', 'بالوزن'), ('piece', 'بالقطعة')],
          onPick: (v) => setState(() => _trackingFilter = v),
        ),
        SegmentedButton<_Status>(
          key: const Key('categories-status'),
          showSelectedIcon: false,
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          segments: const [
            ButtonSegment(value: _Status.all, label: Text('الكل')),
            ButtonSegment(value: _Status.active, label: Text('النشطة')),
            ButtonSegment(value: _Status.stopped, label: Text('الموقوفة')),
          ],
          selected: {_statusFilter},
          onSelectionChanged: (s) => setState(() => _statusFilter = s.first),
        ),
        Text(
          '${_shown.length} من ${all.length}',
          key: const Key('categories-count'),
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      child: wide
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [SizedBox(width: 320, child: search), const SizedBox(width: 16), Expanded(child: chips)],
            )
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [search, const SizedBox(height: 10), chips]),
    );
  }

  Widget _menuChip<T>({
    required Key key,
    required String label,
    required bool active,
    required List<(T, String)> items,
    required ValueChanged<T> onPick,
  }) {
    return PopupMenuButton<int>(
      key: key,
      tooltip: label,
      itemBuilder: (_) => [
        for (var i = 0; i < items.length; i++) PopupMenuItem(value: i, child: Text(items[i].$2)),
      ],
      onSelected: (i) => onPick(items[i].$1),
      child: Chip(
        avatar: Icon(Icons.filter_list, size: 18, color: active ? Theme.of(context).colorScheme.primary : null),
        label: Text(label),
        side: active ? BorderSide(color: Theme.of(context).colorScheme.primary) : null,
      ),
    );
  }

  Widget _karatChip(Category c) {
    final k = int.tryParse(c.karat ?? '');
    final tone = k == null ? AppSemanticColors.of(context).gold : AppSemanticColors.of(context).karat(k);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(999)),
      child: Text(k == null ? '—' : '$k',
          style: Theme.of(context).textTheme.labelLarge?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w800)),
    );
  }

  Widget _status(bool active) {
    final tones = AppSemanticColors.of(context);
    final tone = active ? tones.ready : tones.blocked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(999)),
      child: Text(active ? 'نشط' : 'موقوف',
          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone.onContainer, fontWeight: FontWeight.w700)),
    );
  }

  Widget _scrapTag() {
    final tone = AppSemanticColors.of(context).invoicePurchaseScrap;
    return Container(
      margin: const EdgeInsetsDirectional.only(start: 6),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(6)),
      child: Text('كسر', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: tone.onContainer)),
    );
  }

  Widget _menu(Category c, bool wide) {
    final cs = Theme.of(context).colorScheme;
    return PopupMenuButton<String>(
      key: Key('category-menu-${c.id}'),
      tooltip: 'المزيد',
      icon: Icon(Icons.more_vert, color: cs.onSurfaceVariant),
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: 'edit',
          child: ListTile(leading: Icon(Icons.edit_outlined), title: Text('تعديل'), contentPadding: EdgeInsets.zero),
        ),
        PopupMenuItem(
          value: 'toggle',
          child: ListTile(
            leading: Icon(c.isActive ? Icons.pause_circle_outline : Icons.play_circle_outline),
            title: Text(c.isActive ? 'إيقاف' : 'إعادة تفعيل'),
            contentPadding: EdgeInsets.zero,
          ),
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
      onSelected: (v) => switch (v) {
        'edit' => _openForm(c, wide: wide),
        'toggle' => _toggleActive(c),
        _ => _delete(c),
      },
    );
  }

  // ── a wide screen: the table ──────────────────────────────────────────

  static const _columns = {
    'name': AppTableColumn(220, grow: 3),
    'karat': AppTableColumn(76),
    'section': AppTableColumn(150, grow: 1),
    'tracking': AppTableColumn(100),
    'sizes': AppTableColumn(130, grow: 1),
    'wage': AppTableColumn(110),
    'items': AppTableColumn(80),
    'status': AppTableColumn(90),
    'actions': AppTableColumn(56),
  };

  Widget _table(List<Category> shown) {
    return AppTableFrame(
      columns: _columns,
      onRefresh: _load,
      rowCount: shown.length,
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
            cell('name', 'التصنيف'),
            cell('karat', 'العيار'),
            cell('section', 'القسم'),
            cell('tracking', 'التتبّع'),
            cell('sizes', 'المقاسات'),
            cell('wage', 'الأجور/جم'),
            cell('items', 'الأصناف'),
            cell('status', 'الحالة'),
            cell('actions', ''),
          ]),
        );
      },
      row: (context, i, widths) {
        final theme = Theme.of(context);
        final cs = theme.colorScheme;
        final c = shown[i];
        final muted = cs.onSurfaceVariant;
        final selected = _editing?.id == c.id;
        Widget pad(String key, Widget child) => SizedBox(
          width: widths[key],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(alignment: AlignmentDirectional.centerStart, child: child),
          ),
        );
        return Material(
          color: selected ? cs.secondaryContainer : (i.isOdd ? cs.surfaceContainerLowest : cs.surface),
          child: InkWell(
            key: Key('category-row-${c.id}'),
            onTap: () => _openForm(c, wide: true),
            child: Container(
              height: 56,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6))),
              ),
              child: Row(children: [
                pad('name', Row(children: [
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodyLarge?.copyWith(
                                fontWeight: FontWeight.w700, color: c.isActive ? null : muted)),
                        if ((c.description ?? '').isNotEmpty)
                          Text(c.description!, maxLines: 1, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                      ],
                    ),
                  ),
                  if (c.isScrap) _scrapTag(),
                ])),
                pad('karat', _karatChip(c)),
                pad('section', Text(c.sectionName ?? '—', maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: c.sectionName == null ? muted : null))),
                pad('tracking', Text(c.tracking == 'piece' ? 'بالقطعة' : 'بالوزن', style: theme.textTheme.bodyMedium)),
                pad('sizes', Text(_systemName(c.sizeSystemId), maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(color: c.sizeSystemId == null ? muted : null))),
                pad('wage', Text(_wage(c.defaultWage), style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()]))),
                pad('items', Text('${c.itemsCount ?? 0}', style: theme.textTheme.bodyMedium?.copyWith(
                    fontFeatures: const [FontFeature.tabularFigures()], fontWeight: FontWeight.w700))),
                pad('status', _status(c.isActive)),
                SizedBox(width: widths['actions'], child: _menu(c, true)),
              ]),
            ),
          ),
        );
      },
    );
  }

  // ── a phone: the cards ────────────────────────────────────────────────

  Widget _cards(List<Category> shown) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: shown.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final c = shown[i];
          final facts = [
            c.sectionName ?? 'بلا قسم',
            c.tracking == 'piece' ? 'بالقطعة' : 'بالوزن',
            if (c.sizeSystemId != null) _systemName(c.sizeSystemId),
            if ((c.defaultWage ?? 0) > 0) 'أجور ${_wage(c.defaultWage)}/جم',
            itemsLabel(c.itemsCount ?? 0),
          ];
          return Material(
            key: Key('category-card-${c.id}'),
            color: cs.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: cs.outlineVariant),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _openForm(c, wide: false),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
                child: Row(
                  children: [
                    _karatChip(c),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(
                              child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.titleSmall?.copyWith(
                                      fontWeight: FontWeight.w800, color: c.isActive ? null : cs.onSurfaceVariant)),
                            ),
                            if (c.isScrap) _scrapTag(),
                          ]),
                          const SizedBox(height: 2),
                          Text(facts.join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    if (!c.isActive) _status(false),
                    _menu(c, false),
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

/// A category on a phone: its form, a page of its own.
class _CategoryFormPage extends StatelessWidget {
  const _CategoryFormPage({required this.api, required this.category, required this.sections, required this.systems});

  final ApiService api;
  final Category? category;
  final List<Map<String, dynamic>> sections;
  final List<Map<String, dynamic>>? systems;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: _CategoryForm(
        api: api,
        category: category,
        sections: sections,
        systems: systems,
        onCancel: () => Navigator.of(context).pop(false),
        onSaved: () => Navigator.of(context).pop(true),
      ),
    ),
  );
}

/// A category added or edited: its name and karat, its section, how it is
/// tracked and its sizes, its wage, its description, its state. Each field's
/// law the server's -- a used category's karat is fixed, a tracking changed
/// with pieces is refused -- said in its words.
class _CategoryForm extends StatefulWidget {
  const _CategoryForm({
    super.key,
    required this.api,
    required this.category,
    required this.sections,
    required this.systems,
    required this.onCancel,
    required this.onSaved,
  });

  final ApiService api;
  final Category? category;
  final List<Map<String, dynamic>> sections;
  final List<Map<String, dynamic>>? systems;
  final VoidCallback onCancel;
  final VoidCallback onSaved;

  @override
  State<_CategoryForm> createState() => _CategoryFormState();
}

class _CategoryFormState extends State<_CategoryForm> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _wage;
  late final TextEditingController _description;
  int? _karat;
  int? _section;
  late String _tracking;
  int? _system;
  late bool _active;
  bool _saving = false;

  Category? get _c => widget.category;

  @override
  void initState() {
    super.initState();
    final c = _c;
    _name = TextEditingController(text: c?.name ?? '');
    _wage = TextEditingController(
      text: (c?.defaultWage ?? 0) > 0 ? '${c!.defaultWage}' : '',
    );
    _description = TextEditingController(text: c?.description ?? '');
    _karat = int.tryParse(c?.karat ?? '');
    _section = c?.sectionId;
    _tracking = c?.tracking ?? 'weight';
    _system = c?.sizeSystemId;
    _active = c?.isActive ?? true;
  }

  @override
  void dispose() {
    _name.dispose();
    _wage.dispose();
    _description.dispose();
    super.dispose();
  }

  InputDecoration _field(String label, {String? hint, IconData? icon, String? suffix}) => InputDecoration(
    labelText: label,
    hintText: hint,
    suffixText: suffix,
    prefixIcon: icon == null ? null : Icon(icon),
    isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
  );

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_karat == null) {
      AppFeedback.warning(context, 'اختر عيار التصنيف');
      return;
    }
    setState(() => _saving = true);
    final wage = double.tryParse(_wage.text.trim().replaceAll(',', '.'));
    try {
      final base = {
        'name': _name.text.trim(),
        'description': _description.text.trim(),
        'karat': '$_karat',
        'default_wage': wage,
      };
      final c = _c;
      if (c == null) {
        final made = await widget.api.addCategory(base);
        final id = made['id'] as int?;
        // What a new one is given beyond its name and karat: its section, its
        // tracking, its sizes -- set as an edit sets them (their laws there).
        final more = {
          if (_section != null) 'section_id': _section,
          if (_tracking != 'weight') 'tracking': _tracking,
          if (_system != null) 'size_system_id': _system,
        };
        if (id != null && more.isNotEmpty) await widget.api.updateCategory(id, more);
      } else {
        await widget.api.updateCategory(c.id!, {
          ...base,
          if (_section != c.sectionId) 'section_id': _section,
          if (_tracking != c.tracking) 'tracking': _tracking,
          if (_system != c.sizeSystemId) 'size_system_id': _system,
          if (_active != c.isActive) 'is_active': _active,
        });
      }
      if (mounted) widget.onSaved();
    } catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      AppFeedback.error(context, error, title: 'لم يُحفظ التصنيف');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final scrap = _c?.isScrap ?? false;
    final used = (_c?.itemsCount ?? 0) > 0;
    Widget label(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 8),
          child: Row(children: [
            Expanded(
              child: Text(
                _c == null ? 'تصنيف جديد' : 'تعديل «${_c!.name}»',
                key: const Key('category-form-title'),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            IconButton(tooltip: 'إغلاق', icon: const Icon(Icons.close), onPressed: widget.onCancel),
          ]),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        Expanded(
          child: Form(
            key: _formKey,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                TextFormField(
                  key: const Key('category-name'),
                  controller: _name,
                  autofocus: _c == null,
                  decoration: _field('اسم التصنيف *', icon: Icons.label_outline, hint: 'مثال: خواتم 21'),
                  validator: (v) => (v ?? '').trim().isEmpty ? 'مطلوب' : null,
                ),
                const SizedBox(height: 16),
                label('العيار *'),
                SegmentedButton<int>(
                  key: const Key('category-karat'),
                  showSelectedIcon: false,
                  emptySelectionAllowed: true,
                  segments: [for (final k in _karats) ButtonSegment(value: k, label: Text('$k'))],
                  selected: {?_karat},
                  onSelectionChanged: (s) => setState(() => _karat = s.isEmpty ? null : s.first),
                ),
                if (used)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('عليه ${itemsLabel(_c!.itemsCount!)}: لا يتغيّر عياره بعد استعماله.',
                        style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                  ),
                const SizedBox(height: 16),
                DropdownButtonFormField<int?>(
                  key: const Key('category-section'),
                  initialValue: _section,
                  isExpanded: true,
                  decoration: _field('القسم', icon: Icons.account_tree_outlined),
                  items: [
                    const DropdownMenuItem<int?>(value: null, child: Text('بلا قسم')),
                    for (final s in widget.sections)
                      DropdownMenuItem<int?>(value: s['id'] as int, child: Text('${s['name']}')),
                  ],
                  onChanged: (v) => setState(() => _section = v),
                ),
                if (!scrap) ...[
                  const SizedBox(height: 16),
                  label('طريقة التتبّع'),
                  SegmentedButton<String>(
                    key: const Key('category-tracking'),
                    showSelectedIcon: false,
                    segments: const [
                      ButtonSegment(value: 'weight', label: Text('بالوزن'), icon: Icon(Icons.scale_outlined)),
                      ButtonSegment(value: 'piece', label: Text('بالقطعة'), icon: Icon(Icons.qr_code_2)),
                    ],
                    selected: {_tracking},
                    onSelectionChanged: (s) => setState(() => _tracking = s.first),
                  ),
                  if (_tracking == 'piece')
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text('تُرمَّز كل قطعة منه في «محطة ترميز القطع».',
                          style: theme.textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant)),
                    ),
                  if (widget.systems != null) ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<int?>(
                      key: const Key('category-size-system'),
                      initialValue: _system,
                      isExpanded: true,
                      decoration: _field('نظام المقاسات', icon: Icons.straighten),
                      items: [
                        const DropdownMenuItem<int?>(value: null, child: Text('بلا مقاس')),
                        for (final s in widget.systems!)
                          DropdownMenuItem<int?>(value: s['id'] as int, child: Text('${s['name']}')),
                      ],
                      onChanged: (v) => setState(() => _system = v),
                    ),
                  ],
                ],
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('category-wage'),
                  controller: _wage,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: _field('متوسط الأجور المصنعية', icon: Icons.build_circle_outlined,
                      hint: 'اختياري، مثال: 15.5', suffix: 'ريال/جم'),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  key: const Key('category-description'),
                  controller: _description,
                  maxLines: 2,
                  decoration: _field('الوصف', icon: Icons.notes),
                ),
                if (_c != null) ...[
                  const SizedBox(height: 8),
                  SwitchListTile(
                    key: const Key('category-active'),
                    contentPadding: EdgeInsets.zero,
                    title: Text(_active ? 'نشط' : 'موقوف'),
                    subtitle: Text(_active ? 'يُعرض في الفواتير والأصناف' : 'لا يُعرض لأحد، وفواتيره كما هي'),
                    value: _active,
                    onChanged: (v) => setState(() => _active = v),
                  ),
                ],
              ],
            ),
          ),
        ),
        Divider(height: 1, color: cs.outlineVariant),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: widget.onCancel, child: const Text('إلغاء')),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const Key('category-save'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : Icon(_c == null ? Icons.add : Icons.save_outlined),
                label: Text(_c == null ? 'إضافة' : 'حفظ'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
