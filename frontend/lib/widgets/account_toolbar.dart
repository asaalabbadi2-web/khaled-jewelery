import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../providers/accounts_tree_provider.dart';

class AccountToolbar extends StatelessWidget {
  final AccountsTreeProvider provider;
  final TextEditingController searchController;
  final VoidCallback onExpandAll;
  final VoidCallback onCollapseAll;

  const AccountToolbar({
    super.key,
    required this.provider,
    required this.searchController,
    required this.onExpandAll,
    required this.onCollapseAll,
  });

  static const _typeOptions = [
    ('', 'الكل'),
    ('asset', 'أصول'),
    ('liability', 'خصوم'),
    ('equity', 'حقوق'),
    ('revenue', 'إيرادات'),
    ('expense', 'مصروفات'),
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ─ Search row
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: TextField(
            controller: searchController,
            textDirection: TextDirection.rtl,
            decoration: InputDecoration(
              hintText: 'بحث باسم الحساب أو رقمه...',
              hintStyle: const TextStyle(fontFamily: 'Cairo', fontSize: 13),
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, size: 16),
                      onPressed: () {
                        searchController.clear();
                        provider.setSearch('');
                      },
                    )
                  : null,
              isDense: true,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide:
                    BorderSide(color: Colors.grey.shade300),
              ),
              filled: true,
              fillColor: Colors.grey.shade50,
            ),
            onChanged: provider.setSearch,
          ),
        ),
        // ─ Controls row
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: Row(
            children: [
              // Count chip
              _CountChip(provider: provider),
              const SizedBox(width: 8),
              // Expand / Collapse
              _ToolBtn(
                icon: Icons.unfold_more,
                tooltip: 'توسيع الكل',
                onTap: onExpandAll,
              ),
              _ToolBtn(
                icon: Icons.unfold_less,
                tooltip: 'طي الكل',
                onTap: onCollapseAll,
              ),
              const SizedBox(width: 4),
              // Show balances toggle
              _ToggleBtn(
                icon: Icons.account_balance_wallet_outlined,
                tooltip: 'عرض الأرصدة',
                active: provider.showBalances,
                onTap: provider.toggleBalances,
              ),
              // Postable only
              _ToggleBtn(
                icon: Icons.edit_note,
                tooltip: 'فقط القابلة للقيد',
                active: provider.showOnlyPostable,
                onTap: provider.togglePostableOnly,
              ),
              const SizedBox(width: 4),
              // Sort
              _SortMenu(provider: provider),
              const SizedBox(width: 4),
              // Type filter chips
              for (final opt in _typeOptions)
                Padding(
                  padding: const EdgeInsetsDirectional.only(start: 4),
                  child: _FilterChip(
                    label: opt.$2,
                    selected: provider.typeFilter == opt.$1,
                    onTap: () => provider.setTypeFilter(opt.$1),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _CountChip extends StatelessWidget {
  final AccountsTreeProvider provider;
  const _CountChip({required this.provider});

  @override
  Widget build(BuildContext context) {
    final vis = provider.visibleCount;
    final tot = provider.totalCount;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.goldTone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        vis == tot ? '$tot حساب' : '$vis / $tot',
        style: const TextStyle(
          fontSize: 11,
          fontFamily: 'Cairo',
          color: AppColors.goldTone,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ToolBtn(
      {required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon, size: 18, color: AppColors.muted),
          ),
        ),
      );
}

class _ToggleBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;
  const _ToggleBtn(
      {required this.icon,
      required this.tooltip,
      required this.active,
      required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Icon(icon,
                size: 18,
                color: active ? AppColors.goldTone : AppColors.muted),
          ),
        ),
      );
}

class _SortMenu extends StatelessWidget {
  final AccountsTreeProvider provider;
  const _SortMenu({required this.provider});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<AccountSortOrder>(
      tooltip: 'ترتيب',
      offset: const Offset(0, 32),
      icon: const Icon(Icons.sort, size: 18, color: AppColors.muted),
      onSelected: provider.setSortOrder,
      itemBuilder: (_) => [
        _sortItem(AccountSortOrder.number, 'رقم الحساب',
            provider.sortOrder == AccountSortOrder.number),
        _sortItem(AccountSortOrder.name, 'اسم الحساب',
            provider.sortOrder == AccountSortOrder.name),
        _sortItem(AccountSortOrder.balance, 'الرصيد',
            provider.sortOrder == AccountSortOrder.balance),
      ],
    );
  }

  PopupMenuItem<AccountSortOrder> _sortItem(
      AccountSortOrder v, String label, bool selected) {
    return PopupMenuItem(
      value: v,
      child: Row(children: [
        Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
            size: 16,
            color: selected ? AppColors.goldTone : AppColors.muted),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
      ]),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _FilterChip(
      {required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppColors.goldTone
              : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'Cairo',
            fontWeight:
                selected ? FontWeight.w700 : FontWeight.normal,
            color: selected ? Colors.white : AppColors.muted,
          ),
        ),
      ),
    );
  }
}
