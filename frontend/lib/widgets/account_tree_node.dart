import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../models/account_node.dart';
import '../providers/accounts_tree_provider.dart';
import 'account_type_badge.dart';

final _cashFmt = NumberFormat('#,##0.00', 'ar');
final _goldFmt = NumberFormat('#,##0.###', 'ar');

class AccountTreeNodeWidget extends StatefulWidget {
  final AccountNode node;
  final int depth;
  final List<bool> parentHasMore; // ancestor levels: true = still has siblings below
  final bool isLast;
  final AccountsTreeProvider provider;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(int) onDelete;
  final void Function(Map<String, dynamic>) onAddChild;
  final void Function(Map<String, dynamic>) onStatement;
  final String searchQuery;

  const AccountTreeNodeWidget({
    super.key,
    required this.node,
    required this.depth,
    required this.parentHasMore,
    required this.isLast,
    required this.provider,
    required this.onEdit,
    required this.onDelete,
    required this.onAddChild,
    required this.onStatement,
    this.searchQuery = '',
  });

  @override
  State<AccountTreeNodeWidget> createState() => _AccountTreeNodeWidgetState();
}

class _AccountTreeNodeWidgetState extends State<AccountTreeNodeWidget>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  late AnimationController _arrowCtrl;
  late Animation<double> _arrowAnim;

  @override
  void initState() {
    super.initState();
    _arrowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _arrowAnim = Tween<double>(begin: 0, end: 0.5).animate(
      CurvedAnimation(parent: _arrowCtrl, curve: Curves.easeInOut),
    );
  }

  @override
  void didUpdateWidget(covariant AccountTreeNodeWidget old) {
    super.didUpdateWidget(old);
    final expanded = widget.provider.isExpanded(widget.node.id);
    expanded ? _arrowCtrl.forward() : _arrowCtrl.reverse();
  }

  @override
  void dispose() {
    _arrowCtrl.dispose();
    super.dispose();
  }

  bool get _expanded => widget.provider.isExpanded(widget.node.id);
  bool get _selected =>
      widget.provider.selectedNode?.id == widget.node.id;

  // ─── Balance rendering ───────────────────────────────────────────────────

  Widget _buildBalanceCell() {
    if (!widget.provider.showBalances) return const SizedBox(width: 8);

    final node = widget.node;
    final cash = node.isParent ? node.rolledUpCash : node.ownCash;
    final wt = node.isParent ? node.rolledUpWeightTotal : node.ownWeightTotal;

    final showCash = !node.tracksWeight || node.isParent;
    final showGold = node.tracksWeight || (node.isParent && wt != 0);

    return SizedBox(
      width: 130,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showCash) _cashBadge(cash, node.isParent),
          if (showGold && wt != 0)
            _goldBadge(wt, node.dominantKarat, node.isParent),
        ],
      ),
    );
  }

  Widget _cashBadge(double v, bool isParent) {
    final color = v >= 0 ? AppColors.debit : AppColors.credit;
    return Text(
      _cashFmt.format(v.abs()),
      style: TextStyle(
        fontSize: isParent ? 12 : 11,
        fontWeight: isParent ? FontWeight.w700 : FontWeight.w500,
        color: color,
        fontFamily: 'Cairo',
      ),
    );
  }

  Widget _goldBadge(double wt, int karat, bool isParent) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (karat > 0)
          Container(
            margin: const EdgeInsetsDirectional.only(start: 4),
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.goldTone.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              '${karat}K',
              style: const TextStyle(
                fontSize: 9,
                color: AppColors.goldTone,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        Text(
          '${_goldFmt.format(wt)} جم',
          style: TextStyle(
            fontSize: isParent ? 11 : 10,
            fontWeight: isParent ? FontWeight.w700 : FontWeight.w500,
            color: AppColors.goldTone,
            fontFamily: 'Cairo',
          ),
        ),
      ],
    );
  }

  // ─── Tree lines ──────────────────────────────────────────────────────────

  Widget _buildTreeLines() {
    const lineWidth = 20.0;
    return SizedBox(
      width: lineWidth * widget.depth,
      child: Row(
        children: [
          for (int i = 0; i < widget.depth; i++)
            SizedBox(
              width: lineWidth,
              child: CustomPaint(
                painter: _TreeLinePainter(
                  isLast: i == widget.depth - 1 ? widget.isLast : false,
                  hasMore: i < widget.parentHasMore.length
                      ? widget.parentHasMore[i]
                      : false,
                  isDeepest: i == widget.depth - 1,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ─── Name with search highlight ──────────────────────────────────────────

  Widget _buildName() {
    final fullName = '${widget.node.number}  ${widget.node.name}';
    final q = widget.searchQuery;
    if (q.isEmpty) {
      return Text(
        fullName,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: widget.node.isParent ? 13 : 12,
          fontWeight:
              widget.node.isParent ? FontWeight.w700 : FontWeight.normal,
          fontFamily: 'Cairo',
          color: Colors.black87,
        ),
      );
    }
    // highlight
    final idx = fullName.indexOf(q);
    if (idx < 0) {
      return Text(fullName,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontFamily: 'Cairo'));
    }
    return RichText(
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(
          fontSize: widget.node.isParent ? 13 : 12,
          fontFamily: 'Cairo',
          color: Colors.black87,
        ),
        children: [
          TextSpan(text: fullName.substring(0, idx)),
          TextSpan(
            text: fullName.substring(idx, idx + q.length),
            style: const TextStyle(
              backgroundColor: Color(0xFFFFF59D),
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(text: fullName.substring(idx + q.length)),
        ],
      ),
    );
  }

  // ─── Inline actions (desktop hover) ──────────────────────────────────────

  Widget _buildInlineActions() {
    // Always rendered (no layout shift) — opacity changes only
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _actionIcon(Icons.description_outlined, 'كشف الحساب', AppColors.muted,
            () => widget.onStatement(widget.node.account)),
        _actionIcon(Icons.add_circle_outline, 'إضافة فرعي', AppColors.debit,
            () => widget.onAddChild(widget.node.account)),
        _actionIcon(Icons.edit_outlined, 'تعديل', AppColors.muted,
            () => widget.onEdit(widget.node.account)),
        _actionIcon(Icons.delete_outline, 'حذف', AppColors.credit,
            () => widget.onDelete(widget.node.id)),
      ],
    );
  }

  Widget _actionIcon(
      IconData icon, String tooltip, Color color, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 16, color: color),
        ),
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final node = widget.node;
    final isParent = node.isParent;
    final rowColor = _selected
        ? AppColors.goldTone.withValues(alpha: 0.10)
        : isParent
            ? AppColors.parentRowBg
            : Colors.white;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ─ Row
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: GestureDetector(
            onTap: () {
              widget.provider.select(node);
              if (isParent) widget.provider.toggleExpand(node.id);
            },
            onLongPress: () => widget.onEdit(node.account),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              color: _hovered
                  ? AppColors.treeLine.withValues(alpha: 0.6)
                  : rowColor,
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  // tree lines
                  _buildTreeLines(),
                  // expand arrow
                  SizedBox(
                    width: 20,
                    child: isParent
                        ? RotationTransition(
                            turns: _arrowAnim,
                            child: const Icon(Icons.expand_more,
                                size: 16, color: AppColors.expandArrow),
                          )
                        : const SizedBox.shrink(),
                  ),
                  // folder vs file icon
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: Icon(
                      isParent
                          ? (_expanded
                              ? Icons.folder_open_outlined
                              : Icons.folder_outlined)
                          : Icons.receipt_long_outlined,
                      size: 15,
                      color: isParent
                          ? AppColors.goldTone
                          : AppColors.muted,
                    ),
                  ),
                  // name
                  Expanded(child: _buildName()),
                  // type badge (only leaf or top-level)
                  if (node.depth0 || node.isPostable)
                    Padding(
                      padding: const EdgeInsetsDirectional.only(start: 6),
                      child: AccountTypeBadge(type: node.type),
                    ),
                  // Inline actions + overflow always rendered — only opacity
                  // switches. This prevents layout-shift-induced hover jitter.
                  Opacity(
                    opacity: _hovered ? 1.0 : 0.0,
                    child: IgnorePointer(
                      ignoring: !_hovered,
                      child: _buildInlineActions(),
                    ),
                  ),
                  Opacity(
                    opacity: _hovered ? 0.0 : 1.0,
                    child: IgnorePointer(
                      ignoring: _hovered,
                      child: _OverflowMenu(
                        node: node,
                        onEdit: widget.onEdit,
                        onDelete: widget.onDelete,
                        onAddChild: widget.onAddChild,
                        onStatement: widget.onStatement,
                      ),
                    ),
                  ),
                  // balance
                  _buildBalanceCell(),
                ],
              ),
            ),
          ),
        ),
        // ─ Children
        if (isParent && _expanded)
          for (int i = 0; i < node.children.length; i++)
            AccountTreeNodeWidget(
              key: ValueKey(node.children[i].id),
              node: node.children[i],
              depth: widget.depth + 1,
              parentHasMore: [
                ...widget.parentHasMore,
                !widget.isLast,
              ],
              isLast: i == node.children.length - 1,
              provider: widget.provider,
              onEdit: widget.onEdit,
              onDelete: widget.onDelete,
              onAddChild: widget.onAddChild,
              onStatement: widget.onStatement,
              searchQuery: widget.searchQuery,
            ),
      ],
    );
  }
}

// ─── Helper extension ─────────────────────────────────────────────────────────
extension _NodeDepth on AccountNode {
  bool get depth0 => parentId == null;
}

// ─── Tree line painter ────────────────────────────────────────────────────────
class _TreeLinePainter extends CustomPainter {
  final bool isLast;
  final bool hasMore;
  final bool isDeepest;

  const _TreeLinePainter(
      {required this.isLast, required this.hasMore, required this.isDeepest});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.treeLine
      ..strokeWidth = 1.0;

    final midX = size.width / 2;
    final midY = size.height / 2;

    if (isDeepest) {
      // vertical line above mid
      canvas.drawLine(Offset(midX, 0), Offset(midX, midY), paint);
      // vertical line below mid only if not last
      if (!isLast) {
        canvas.drawLine(Offset(midX, midY), Offset(midX, size.height), paint);
      }
      // horizontal stub to the right
      canvas.drawLine(Offset(midX, midY), Offset(size.width, midY), paint);
    } else {
      // ancestor levels: only vertical pass-through if ancestor still has siblings
      if (hasMore) {
        canvas.drawLine(Offset(midX, 0), Offset(midX, size.height), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TreeLinePainter old) =>
      old.isLast != isLast ||
      old.hasMore != hasMore ||
      old.isDeepest != isDeepest;
}

// ─── Overflow menu (shown on touch / when not hovered) ───────────────────────
class _OverflowMenu extends StatelessWidget {
  final AccountNode node;
  final void Function(Map<String, dynamic>) onEdit;
  final void Function(int) onDelete;
  final void Function(Map<String, dynamic>) onAddChild;
  final void Function(Map<String, dynamic>) onStatement;

  const _OverflowMenu({
    required this.node,
    required this.onEdit,
    required this.onDelete,
    required this.onAddChild,
    required this.onStatement,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      tooltip: 'خيارات',
      icon: const Icon(Icons.more_vert, size: 18, color: AppColors.muted),
      onSelected: (v) {
        switch (v) {
          case 'statement':
            onStatement(node.account);
          case 'add':
            onAddChild(node.account);
          case 'edit':
            onEdit(node.account);
          case 'delete':
            onDelete(node.id);
        }
      },
      itemBuilder: (_) => [
        _item('statement', 'كشف الحساب', Icons.description_outlined),
        _item('add', 'إضافة فرعي', Icons.add_circle_outline,
            color: AppColors.debit),
        _item('edit', 'تعديل', Icons.edit_outlined),
        _item('delete', 'حذف', Icons.delete_outline, color: AppColors.credit),
      ],
    );
  }

  PopupMenuItem<String> _item(String v, String label, IconData icon,
      {Color color = AppColors.muted}) {
    return PopupMenuItem(
      value: v,
      child: Row(children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 10),
        Text(label, style: const TextStyle(fontFamily: 'Cairo', fontSize: 13)),
      ]),
    );
  }
}
