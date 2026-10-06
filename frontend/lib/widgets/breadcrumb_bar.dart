import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/account_node.dart';

class BreadcrumbBar extends StatelessWidget {
  final AccountNode? selectedNode;
  final List<AccountNode> allRoots;
  final void Function(AccountNode) onTap;

  const BreadcrumbBar({
    super.key,
    required this.selectedNode,
    required this.allRoots,
    required this.onTap,
  });

  List<AccountNode> _buildPath(AccountNode target, List<AccountNode> nodes) {
    for (final n in nodes) {
      if (n.id == target.id) return [n];
      final sub = _buildPath(target, n.children);
      if (sub.isNotEmpty) return [n, ...sub];
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    if (selectedNode == null) return const SizedBox.shrink();

    final path = _buildPath(selectedNode!, allRoots);
    if (path.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 36,
      color: AppColors.parentRowBg,
      padding: const EdgeInsetsDirectional.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.account_tree_outlined,
              size: 14, color: AppColors.muted),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (int i = 0; i < path.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 4),
                        child: Icon(Icons.chevron_left,
                            size: 14, color: AppColors.muted),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(4),
                      onTap: () => onTap(path[i]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        child: Text(
                          '${path[i].number} ${path[i].name}',
                          style: TextStyle(
                            fontSize: 12,
                            color: i == path.length - 1
                                ? AppColors.goldTone
                                : AppColors.muted,
                            fontWeight: i == path.length - 1
                                ? FontWeight.w600
                                : FontWeight.normal,
                            fontFamily: 'Cairo',
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
