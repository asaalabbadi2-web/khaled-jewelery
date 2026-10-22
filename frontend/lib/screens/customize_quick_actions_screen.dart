import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/quick_actions_provider.dart';
import '../models/quick_action_item.dart';
import '../theme/app_semantic_colors.dart';
import '../theme/app_theme.dart';
import '../widgets/app_bar_tab_bar.dart';
import '../widgets/app_state_views.dart';
import '../utils/arabic_search.dart';
import '../widgets/app_feedback.dart';

class _AddActionResult {
  final QuickActionItem? action;
  final QuickActionAddStatus status;

  const _AddActionResult({required this.action, required this.status});
}

/// شاشة تخصيص أزرار الوصول السريع — تبويب لكل مجموعة
class CustomizeQuickActionsScreen extends StatefulWidget {
  final QuickActionGroup? initialGroup;

  const CustomizeQuickActionsScreen({super.key, this.initialGroup});

  @override
  State<CustomizeQuickActionsScreen> createState() =>
      _CustomizeQuickActionsScreenState();
}

class _CustomizeQuickActionsScreenState
    extends State<CustomizeQuickActionsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  bool _isReordering = false;

  static const _groups = [
    QuickActionGroup.sales,
    QuickActionGroup.accounting,
    QuickActionGroup.admin,
  ];

  static const _groupTitles = ['المبيعات', 'المحاسبة', 'الإدارة'];

  static const _groupIcons = [
    Icons.receipt_long_rounded,
    Icons.menu_book_rounded,
    Icons.settings_rounded,
  ];

  @override
  void initState() {
    super.initState();
    final initialIndex = widget.initialGroup != null
        ? _groups.indexOf(widget.initialGroup!)
        : 0;
    _tabController = TabController(
      length: _groups.length,
      vsync: this,
      initialIndex: initialIndex.clamp(0, _groups.length - 1),
    );
    _tabController.addListener(() {
      if (_isReordering) setState(() => _isReordering = false);
    });
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  QuickActionGroup get _currentGroup => _groups[_tabController.index];

  // ADR-057 ر٢: colours by meaning, from the theme, in both modes.
  AppSemanticColors get _tone => AppSemanticColors.of(context);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('تخصيص الوصول السريع'),
          actions: [
            IconButton(
              icon: Icon(
                Icons.add_circle_outline,
                color: _isReordering
                    ? theme.disabledColor
                    : _tone.gold.fg,
              ),
              tooltip: 'إضافة زر',
              onPressed: _isReordering ? null : _openAddActionSheet,
            ),
            IconButton(
              icon: Icon(_isReordering ? Icons.done : Icons.reorder),
              tooltip: _isReordering ? 'إنهاء الترتيب' : 'إعادة الترتيب',
              onPressed: () => setState(() => _isReordering = !_isReordering),
            ),
            PopupMenuButton<String>(
              onSelected: (value) {
                if (value == 'reset') _showResetConfirmDialog();
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'reset',
                  child: Row(
                    children: [
                      Icon(Icons.restore),
                      SizedBox(width: 12),
                      Text('إعادة للإعدادات الافتراضية'),
                    ],
                  ),
                ),
              ],
            ),
          ],
          bottom: AppBarTabBar(
            controller: _tabController,
            tabs: List.generate(
              _groups.length,
              (i) => Tab(
                icon: Icon(_groupIcons[i], size: 18),
                text: _groupTitles[i],
              ),
            ),
          ),
        ),
        body: Consumer<QuickActionsProvider>(
          builder: (context, provider, _) {
            if (provider.isLoading) return const AppLoadingView(rows: 5);

            return Column(
              children: [
                _buildInfoBanner(theme),
                if (_tabController.index == 0) ...[
                  _buildSalesRaceSwitch(provider),
                ],
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: _groups.map((group) {
                      return _buildGroupTab(provider, group, theme);
                    }).toList(),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildInfoBanner(ThemeData theme) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _tone.info.container,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: _tone.info.onContainer, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _isReordering
                  ? 'اسحب الأزرار لتغيير ترتيبها داخل القسم'
                  : 'فعّل/عطّل الأزرار التي تريد عرضها في كل قسم',
              style: theme.textTheme.bodySmall?.copyWith(color: _tone.info.onContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSalesRaceSwitch(QuickActionsProvider provider) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: SwitchListTile(
        value: provider.showSalesRaceCard,
        activeThumbColor: _tone.ready.fg,
        title: const Text('عرض كرت سباق المبيعات'),
        subtitle: const Text('إظهار/إخفاء كرت التحدي في الرئيسية'),
        onChanged: (value) async {
          final ok = await provider.setShowSalesRaceCard(value);
          if (!mounted || ok) return;
          AppFeedback.error(context, 'تعذر حفظ الإعداد، حاول مرة أخرى');
        },
      ),
    );
  }

  Widget _buildGroupTab(
    QuickActionsProvider provider,
    QuickActionGroup group,
    ThemeData theme,
  ) {
    final inProviderIds = provider.actions.map((a) => a.id).toSet();

    // Items already tracked in provider for this group
    final inProvider = provider.actions
        .where((a) => a.group == group)
        .toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    // Full catalog items for this group that haven't been added yet
    final notInProvider = DefaultQuickActions.catalogForGroup(group)
        .where((a) => !inProviderIds.contains(a.id))
        .toList();

    final active = inProvider.where((a) => a.isActive).toList();
    final inactiveInProvider = inProvider.where((a) => !a.isActive).toList();

    // Inactive section = disabled-in-provider items + never-added catalog items
    final allInactive = [...inactiveInProvider, ...notInProvider];
    final totalCount = active.length + allInactive.length;

    if (totalCount == 0) {
      return _buildEmptyState(theme);
    }

    final groupIndex = _groups.indexOf(group);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _buildGroupHeader(
            theme,
            _groupTitles[groupIndex],
            _groupIcons[groupIndex],
            active.length,
            totalCount,
          ),
        ),
        if (_isReordering)
          _buildReorderableSliver(provider, active, theme)
        else ...[
          if (active.isNotEmpty) ...[
            SliverToBoxAdapter(child: _buildSubHeader(theme, 'مفعّلة', _tone.ready.fg)),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => _buildToggleItem(active[i], provider, theme, active: true),
                childCount: active.length,
              ),
            ),
          ],
          if (allInactive.isNotEmpty) ...[
            SliverToBoxAdapter(child: _buildSubHeader(theme, 'متاحة للتفعيل', theme.hintColor)),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) {
                  final item = allInactive[i];
                  final isInProvider = inProviderIds.contains(item.id);
                  return _buildToggleItem(
                    item,
                    provider,
                    theme,
                    active: false,
                    onToggleOverride: isInProvider
                        ? null
                        : () async {
                            final status =
                                await provider.addActionFromCatalog(item.id);
                            return status == QuickActionAddStatus.added ||
                                status == QuickActionAddStatus.reactivated;
                          },
                  );
                },
                childCount: allInactive.length,
              ),
            ),
          ],
          SliverToBoxAdapter(child: const SizedBox(height: 24)),
        ],
      ],
    );
  }

  Widget _buildGroupHeader(
    ThemeData theme,
    String title,
    IconData icon,
    int active,
    int total,
  ) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: _tone.gold.fg),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: _tone.ready.container,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              '$active / $total مفعّل',
              style: theme.textTheme.bodySmall?.copyWith(
                color: _tone.ready.onContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubHeader(ThemeData theme, String label, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReorderableSliver(
    QuickActionsProvider provider,
    List<QuickActionItem> active,
    ThemeData theme,
  ) {
    return SliverReorderableList(
      itemCount: active.length,
      onReorder: (oldIndex, newIndex) async {
        await provider.reorderGroupActions(_currentGroup, oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        if (index >= active.length) {
          return const SizedBox.shrink(key: ValueKey('_empty'));
        }
        final action = active[index];
        return ReorderableDragStartListener(
          key: ValueKey(action.id),
          index: index,
          child: Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            color: theme.cardColor,
            elevation: 2,
            child: ListTile(
              leading: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: action.getColor().withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(action.icon, color: action.getColor(), size: 22),
              ),
              title: Text(action.label, style: theme.textTheme.titleSmall),
              trailing: Icon(Icons.drag_handle, color: theme.hintColor),
            ),
          ),
        );
      },
    );
  }

  QuickActionsProvider get provider =>
      Provider.of<QuickActionsProvider>(context, listen: false);

  Widget _buildToggleItem(
    QuickActionItem action,
    QuickActionsProvider provider,
    ThemeData theme, {
    required bool active,
    Future<bool> Function()? onToggleOverride,
  }) {
    final color = action.getColor();
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      color: theme.cardColor,
      elevation: active ? 1.5 : 0.5,
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: color.withValues(alpha: active ? 0.14 : 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            action.icon,
            color: active ? color : theme.colorScheme.onSurfaceVariant,
            size: 22,
          ),
        ),
        title: Text(
          action.label,
          style: theme.textTheme.titleSmall?.copyWith(
            color: active ? null : theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: Switch(
          value: active,
          activeThumbColor: _tone.ready.fg,
          onChanged: (_) async {
            final bool success;
            if (onToggleOverride != null) {
              success = await onToggleOverride();
            } else {
              success = await provider.toggleAction(action.id);
            }
            if (success && mounted) {
              AppFeedback.success(context, !active
                        ? 'تم تفعيل "${action.label}"'
                        : 'تم تعطيل "${action.label}"');
            }
          },
        ),
        onTap: () async {
          if (onToggleOverride != null) {
            await onToggleOverride();
          } else {
            await provider.toggleAction(action.id);
          }
        },
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined, size: 48, color: theme.hintColor),
          const SizedBox(height: 12),
          Text('لا توجد عناصر في هذا القسم', style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }

  void _showResetConfirmDialog() {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor:
              theme.dialogTheme.backgroundColor ?? theme.colorScheme.surface,
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: _tone.warning.fg),
              const SizedBox(width: 12),
              Text('إعادة تعيين', style: theme.textTheme.titleLarge),
            ],
          ),
          content: Text(
            'هل أنت متأكد من إعادة جميع الأزرار إلى الإعدادات الافتراضية؟\n\nسيتم فقد جميع التخصيصات الحالية.',
            style: theme.textTheme.bodyMedium,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('إلغاء', style: TextStyle(color: theme.hintColor)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: theme.colorScheme.onError,
              ),
              onPressed: () async {
                Navigator.pop(context);
                final p = Provider.of<QuickActionsProvider>(
                  context,
                  listen: false,
                );
                final success = await p.resetToDefaults();
                if (success && mounted) {
                  AppFeedback.success(context, 'تم إعادة التعيين بنجاح');
                }
              },
              child: const Text('إعادة تعيين'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openAddActionSheet() async {
    final p = Provider.of<QuickActionsProvider>(context, listen: false);

    // Show only items from current group that aren't already added
    final existingIds = p.actions.map((a) => a.id).toSet();
    final groupCatalog = DefaultQuickActions.catalogForGroup(_currentGroup);
    final availableItems =
        groupCatalog.where((a) => !existingIds.contains(a.id)).toList();

    if (availableItems.isEmpty) {
      AppFeedback.info(context, 'جميع عناصر هذا القسم مضافة بالفعل');
      return;
    }

    String searchQuery = '';

    final result = await showModalBottomSheet<_AddActionResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).dialogTheme.backgroundColor ??
          Theme.of(context).colorScheme.surface,
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: StatefulBuilder(
              builder: (sheetContext, setSheetState) {
                final filtered = availableItems.where((item) {
                  // As people write it (ADR-057 ر٣).
                  final q = normalizeForSearch(searchQuery);
                  return q.isEmpty ||
                      normalizeForSearch(item.label).contains(q) ||
                      normalizeForSearch(item.id).contains(q);
                }).toList();

                return SizedBox(
                  height: MediaQuery.of(sheetContext).size.height * 0.65,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إضافة من قسم ${_groupTitles[_groups.indexOf(_currentGroup)]}',
                              style: sheetTheme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              textDirection: TextDirection.rtl,
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search),
                                hintText: 'ابحث باسم العنصر',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onChanged: (v) =>
                                  setSheetState(() => searchQuery = v),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: filtered.isEmpty
                            ? Center(
                                child: Text(
                                  'لا توجد نتائج',
                                  style: sheetTheme.textTheme.bodyMedium
                                      ?.copyWith(color: sheetTheme.hintColor),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                itemCount: filtered.length,
                                separatorBuilder: (context, i) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, index) {
                                  final action = filtered[index];
                                  final actionColor = action.getColor();

                                  Future<void> handleTap() async {
                                    final status =
                                        await p.addActionFromCatalog(action.id);
                                    if (!mounted) return;
                                    Navigator.of(sheetContext).pop(
                                      _AddActionResult(
                                        action: action,
                                        status: status,
                                      ),
                                    );
                                  }

                                  return Card(
                                    margin: EdgeInsets.zero,
                                    elevation: 1.5,
                                    child: ListTile(
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: actionColor.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(action.icon, color: actionColor),
                                      ),
                                      title: Text(action.label),
                                      trailing: IconButton(
                                        icon: const Icon(Icons.add_circle_outline),
                                        color: _tone.gold.fg,
                                        onPressed: handleTap,
                                      ),
                                      onTap: handleTap,
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );

    if (!mounted || result == null) return;

    final label = result.action?.label ?? '';

    switch (result.status) {
      case QuickActionAddStatus.added:
        AppFeedback.success(context, 'تمت إضافة "$label"');
        break;
      case QuickActionAddStatus.reactivated:
        AppFeedback.success(context, 'تم تفعيل "$label" من جديد');
        break;
      case QuickActionAddStatus.alreadyExists:
        AppFeedback.info(context, '"$label" موجود بالفعل');
        break;
      case QuickActionAddStatus.failed:
        AppFeedback.error(context, 'تعذر الإضافة، حاول مرة أخرى');
        break;
    }
  }
}
