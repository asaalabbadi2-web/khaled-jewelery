import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/quick_actions_provider.dart';
import '../models/quick_action_item.dart';
import '../theme/app_theme.dart';

class _AddActionResult {
  final QuickActionItem? action;
  final QuickActionAddStatus status;

  const _AddActionResult({required this.action, required this.status});
}

/// شاشة تخصيص أزرار الوصول السريع في الشاشة الرئيسية
class CustomizeQuickActionsScreen extends StatefulWidget {
  const CustomizeQuickActionsScreen({Key? key}) : super(key: key);

  @override
  State<CustomizeQuickActionsScreen> createState() =>
      _CustomizeQuickActionsScreenState();
}

class _CustomizeQuickActionsScreenState
    extends State<CustomizeQuickActionsScreen> {
  bool _isReordering = false;

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
                    : AppColors.primaryGold,
              ),
              tooltip: 'إضافة زر جديد',
              onPressed: () {
                if (_isReordering) return;
                _openAddActionSheet();
              },
            ),
            // زر إعادة الترتيب
            IconButton(
              icon: Icon(_isReordering ? Icons.done : Icons.reorder),
              tooltip: _isReordering ? 'إنهاء الترتيب' : 'إعادة الترتيب',
              onPressed: () {
                setState(() {
                  _isReordering = !_isReordering;
                });
              },
            ),
            // زر إعادة التعيين
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'reset') {
                  _showResetConfirmDialog();
                }
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
        ),
        body: Consumer<QuickActionsProvider>(
          builder: (context, provider, child) {
            if (provider.isLoading) {
              return Center(
                child: CircularProgressIndicator(color: AppColors.primaryGold),
              );
            }

            return Column(
              children: [
                // بطاقة المعلومات
                Container(
                  margin: const EdgeInsets.all(16),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.info.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.info.withValues(alpha: 0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline, color: AppColors.info, size: 24),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _isReordering
                              ? 'اسحب الأزرار لتغيير ترتيبها'
                              : 'فعّل/عطّل الأزرار التي تريد عرضها في الشاشة الرئيسية',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: AppColors.info,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // الإحصائيات
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: _buildStatCard(
                          icon: Icons.apps,
                          label: 'الإجمالي',
                          value: provider.actions.length.toString(),
                          color: theme.hintColor,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _buildStatCard(
                          icon: Icons.check_circle,
                          label: 'المفعّلة',
                          value: provider.activeActions.length.toString(),
                          color: AppColors.success,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // قائمة الأزرار
                Expanded(
                  child: _isReordering
                      ? _buildReorderableList(provider)
                      : _buildToggleList(provider),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// بطاقة إحصائية
  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.dividerColor, width: 1),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(height: 8),
          Text(
            value,
            style: theme.textTheme.headlineSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(label, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// قائمة مع إمكانية إعادة الترتيب
  Widget _buildReorderableList(QuickActionsProvider provider) {
    final theme = Theme.of(context);

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: provider.actions.length,
      onReorder: (oldIndex, newIndex) async {
        await provider.reorderActions(oldIndex, newIndex);
      },
      itemBuilder: (context, index) {
        final action = provider.actions[index];
        return _buildReorderableItem(action, theme);
      },
    );
  }

  /// عنصر قابل لإعادة الترتيب
  Widget _buildReorderableItem(QuickActionItem action, ThemeData theme) {
    return Card(
      key: ValueKey(action.id),
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.cardColor,
      elevation: 2,
      child: ListTile(
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: action.getColor().withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(action.icon, color: action.getColor(), size: 24),
        ),
        title: Text(action.label, style: theme.textTheme.titleMedium),
        subtitle: Text(
          'الترتيب: ${action.order + 1}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!action.isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: theme.disabledColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'معطّل',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.disabledColor,
                  ),
                ),
              ),
            const SizedBox(width: 8),
            Icon(Icons.drag_handle, color: theme.hintColor),
          ],
        ),
      ),
    );
  }

  /// قائمة مع إمكانية التفعيل/التعطيل
  Widget _buildToggleList(QuickActionsProvider provider) {
    final theme = Theme.of(context);

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: provider.actions.length,
      itemBuilder: (context, index) {
        final action = provider.actions[index];
        return _buildToggleItem(action, provider, theme);
      },
    );
  }

  /// عنصر مع مفتاح تفعيل/تعطيل
  Widget _buildToggleItem(
    QuickActionItem action,
    QuickActionsProvider provider,
    ThemeData theme,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.cardColor,
      elevation: action.isActive ? 2 : 0.5,
      child: ListTile(
        enabled: true,
        leading: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: action.getColor().withValues(alpha: action.isActive ? 0.15 : 0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            action.icon,
            color: action.isActive ? action.getColor() : theme.disabledColor,
            size: 24,
          ),
        ),
        title: Text(
          action.label,
          style: theme.textTheme.titleMedium?.copyWith(
            color: action.isActive ? null : theme.disabledColor,
          ),
        ),
        subtitle: Text(
          action.isActive ? 'مفعّل • الترتيب: ${action.order + 1}' : 'معطّل',
          style: theme.textTheme.bodySmall?.copyWith(
            color: action.isActive ? AppColors.success : theme.disabledColor,
          ),
        ),
        trailing: Switch(
          value: action.isActive,
          activeColor: AppColors.success,
          onChanged: (value) async {
            final success = await provider.toggleAction(action.id);
            if (success && mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    value
                        ? 'تم تفعيل "${action.label}"'
                        : 'تم تعطيل "${action.label}"',
                  ),
                  backgroundColor: value ? AppColors.success : theme.hintColor,
                  duration: const Duration(seconds: 2),
                ),
              );
            }
          },
        ),
        onTap: () async {
          await provider.toggleAction(action.id);
        },
      ),
    );
  }

  /// حوار تأكيد إعادة التعيين
  void _showResetConfirmDialog() {
    final theme = Theme.of(context);

    showDialog(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          backgroundColor: theme.dialogBackgroundColor,
          title: Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: AppColors.warning),
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
                backgroundColor: AppColors.error,
                foregroundColor: Colors.white,
              ),
              onPressed: () async {
                Navigator.pop(context);
                final provider = Provider.of<QuickActionsProvider>(
                  context,
                  listen: false,
                );
                final success = await provider.resetToDefaults();
                if (success && mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text('تم إعادة التعيين بنجاح'),
                      backgroundColor: AppColors.success,
                    ),
                  );
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
    final provider = Provider.of<QuickActionsProvider>(context, listen: false);
    final availableItems = provider.availableActions;

    if (availableItems.isEmpty) {
      final theme = Theme.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('لا توجد عناصر جديدة لإضافتها حالياً'),
          backgroundColor: theme.hintColor,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    String searchQuery = '';

    final result = await showModalBottomSheet<_AddActionResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).dialogBackgroundColor,
      builder: (sheetContext) {
        final sheetTheme = Theme.of(sheetContext);

        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: StatefulBuilder(
              builder: (sheetContext, setSheetState) {
                final filteredItems = availableItems.where((item) {
                  final query = searchQuery.trim();
                  if (query.isEmpty) return true;
                  final lowerQuery = query.toLowerCase();
                  return item.label.toLowerCase().contains(lowerQuery) ||
                      item.id.toLowerCase().contains(lowerQuery);
                }).toList();

                return SizedBox(
                  height: MediaQuery.of(sheetContext).size.height * 0.75,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'إضافة عناصر جديدة',
                              style: sheetTheme.textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'اختر من القائمة التالية لإضافة عناصر جديدة إلى الوصول السريع.',
                              style: sheetTheme.textTheme.bodySmall,
                            ),
                            const SizedBox(height: 12),
                            TextField(
                              textDirection: TextDirection.rtl,
                              decoration: InputDecoration(
                                prefixIcon: const Icon(Icons.search),
                                hintText: 'ابحث باسم العنصر أو المعرّف',
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              onChanged: (value) =>
                                  setSheetState(() => searchQuery = value),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: filteredItems.isEmpty
                            ? Center(
                                child: Text(
                                  'لا توجد نتائج مطابقة للبحث',
                                  style: sheetTheme.textTheme.bodyMedium
                                      ?.copyWith(color: sheetTheme.hintColor),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  16,
                                  0,
                                  16,
                                  16,
                                ),
                                itemCount: filteredItems.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (_, index) {
                                  final action = filteredItems[index];
                                  final actionColor = action.getColor();

                                  Future<void> handleSelection() async {
                                    final status = await provider
                                        .addActionFromCatalog(action.id);
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
                                    elevation: 2,
                                    child: ListTile(
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 16,
                                            vertical: 12,
                                          ),
                                      leading: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: actionColor.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                        child: Icon(
                                          action.icon,
                                          color: actionColor,
                                        ),
                                      ),
                                      title: Text(
                                        action.label,
                                        style: sheetTheme.textTheme.titleMedium,
                                      ),
                                      subtitle: Text(
                                        'المعرّف: ${action.id}',
                                        style: sheetTheme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: sheetTheme.hintColor,
                                            ),
                                      ),
                                      trailing: IconButton(
                                        icon: const Icon(
                                          Icons.add_circle_outline,
                                        ),
                                        color: AppColors.primaryGold,
                                        tooltip: 'إضافة إلى الوصول السريع',
                                        onPressed: handleSelection,
                                      ),
                                      onTap: handleSelection,
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

    if (!mounted || result == null) {
      return;
    }

    final theme = Theme.of(context);
    final label = result.action?.label ?? '';

    switch (result.status) {
      case QuickActionAddStatus.added:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تمت إضافة "$label" إلى الوصول السريع'),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 2),
          ),
        );
        break;
      case QuickActionAddStatus.reactivated:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم تفعيل "$label" من جديد'),
            backgroundColor: AppColors.success,
            duration: const Duration(seconds: 2),
          ),
        );
        break;
      case QuickActionAddStatus.alreadyExists:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('"$label" موجود بالفعل ضمن الوصول السريع'),
            backgroundColor: theme.hintColor,
            duration: const Duration(seconds: 2),
          ),
        );
        break;
      case QuickActionAddStatus.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('تعذر إضافة العنصر، حاول مرة أخرى'),
            backgroundColor: AppColors.error,
            duration: const Duration(seconds: 2),
          ),
        );
        break;
    }
  }
}
