import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/settings_provider.dart';
import '../theme/app_theme.dart';
import '../utils/bidi.dart';
import '../utils/currency_utils.dart';
import 'app_table.dart';

/// The suppliers' and the customers' list on a wide screen (the owner, 17
/// Nov 2026: «طريقة عرض قائمة الموردين والعملاء في الشاشات العريضة تحتاج
/// تطوير»): one row a party -- 15 to 18 in sight where a card a party gave
/// three -- its balances side by side to be compared at a glance, each said
/// «له» or «عليه» as the statement says it. One table for both lists.

/// A party as its row shows it.
typedef PartyTableRow = ({
  String name,
  String code,
  String phone,
  bool active,
  double cash,

  /// Its gold at the main karat; null when the settings hold none.
  double? gold,
});

/// An action a row offers beside its menu.
typedef PartyTableAction = ({IconData icon, String label, VoidCallback onPressed});

/// The column a list is sorted by, as the header names it.
enum PartyTableSort { name, cash, gold }

/// A wide screen: a table from here, cards below it.
const double partyTableMinWidth = 1100;

class PartyTable extends StatelessWidget {
  const PartyTable({
    super.key,
    required this.rows,
    required this.partyLabel,
    required this.onOpen,
    required this.actions,
    required this.menu,
    required this.onRefresh,
    required this.sort,
    required this.ascending,
    required this.onSort,
    required this.mainKarat,
  });

  final List<PartyTableRow> rows;

  /// «المورد» or «العميل».
  final String partyLabel;
  final void Function(int index) onOpen;
  final List<PartyTableAction> Function(int index) actions;
  final Widget Function(int index) menu;
  final Future<void> Function() onRefresh;
  final PartyTableSort sort;
  final bool ascending;
  final void Function(PartyTableSort sort) onSort;
  final int mainKarat;

  static const _columns = {
    'name': AppTableColumn(240, grow: 3),
    'phone': AppTableColumn(140, grow: 1),
    'status': AppTableColumn(96),
    'cash': AppTableColumn(190, grow: 1),
    'gold': AppTableColumn(170, grow: 1),
    'actions': AppTableColumn(196),
  };

  @override
  Widget build(BuildContext context) {
    return AppTableFrame(
      columns: _columns,
      onRefresh: onRefresh,
      rowCount: rows.length,
      header: (widths) => _header(context, widths),
      row: (context, i, widths) => _row(context, i, widths),
    );
  }

  Widget _header(BuildContext context, Map<String, double> widths) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelLarge?.copyWith(
      fontWeight: FontWeight.w800,
      color: theme.colorScheme.onSurfaceVariant,
    );
    Widget cell(String key, String label, {PartyTableSort? by, bool end = false}) {
      final text = Row(
        mainAxisAlignment: end ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: Text(label, style: style, overflow: TextOverflow.ellipsis)),
          if (by != null && sort == by) ...[
            const SizedBox(width: 4),
            Icon(ascending ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: style?.color),
          ],
        ],
      );
      return SizedBox(
        width: widths[key],
        child: by == null
            ? Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: text)
            : InkWell(
                key: Key('party-sort-${by.name}'),
                onTap: () => onSort(by),
                child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: text),
              ),
      );
    }

    return Container(
      height: 48,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          cell('name', partyLabel, by: PartyTableSort.name),
          cell('phone', 'الهاتف'),
          cell('status', 'الحالة'),
          cell('cash', 'رصيد النقد', by: PartyTableSort.cash, end: true),
          cell('gold', 'رصيد الذهب ($mainKarat)', by: PartyTableSort.gold, end: true),
          cell('actions', ''),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, int i, Map<String, double> widths) {
    final theme = Theme.of(context);
    final r = rows[i];
    final muted = theme.colorScheme.onSurfaceVariant;
    Widget pad(String key, Widget child, {bool end = false}) => SizedBox(
      width: widths[key],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(alignment: end ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart, child: child),
      ),
    );

    return Material(
      color: i.isOdd ? theme.colorScheme.surfaceContainerLowest : theme.colorScheme.surface,
      child: InkWell(
        key: Key('party-row-$i'),
        onTap: () => onOpen(i),
        child: Container(
          height: 56,
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6))),
          ),
          child: Row(
            children: [
              pad(
                'name',
                Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r.name.isEmpty ? 'بدون اسم' : r.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: r.active ? null : muted,
                      ),
                    ),
                    if (r.code.isNotEmpty)
                      Text(ltrIsolate(r.code), style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                  ],
                ),
              ),
              pad(
                'phone',
                Text(
                  r.phone.isEmpty ? '—' : ltrIsolate(r.phone),
                  style: theme.textTheme.bodyMedium?.copyWith(color: muted),
                ),
              ),
              pad('status', _status(context, r.active)),
              pad('cash', PartyBalance(r.cash, cash: true), end: true),
              pad('gold', r.gold == null ? Text('—', style: TextStyle(color: muted)) : PartyBalance(r.gold!, cash: false), end: true),
              SizedBox(
                width: widths['actions'],
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    for (final a in actions(i))
                      IconButton(
                        tooltip: a.label,
                        icon: Icon(a.icon, size: 20),
                        color: theme.colorScheme.primary,
                        onPressed: a.onPressed,
                      ),
                    menu(i),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _status(BuildContext context, bool active) {
    final tones = AppSemanticColors.of(context);
    final tone = active ? tones.ready : tones.blocked;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: tone.container, borderRadius: BorderRadius.circular(AppRadius.chip)),
      child: Text(active ? 'نشط' : 'معطّل', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: tone.onContainer)),
    );
  }
}

/// A party's balance as the statement says it: its size, and «عليه» (more
/// than nothing: owed to us) or «له» (less: we owe) -- no minus sign; «—»
/// for nothing. The table's cell and the phone's card alike.
class PartyBalance extends StatelessWidget {
  const PartyBalance(this.value, {super.key, required this.cash, this.large = true});

  final double value;

  /// Riyals (true) or grams at the main karat.
  final bool cash;
  final bool large;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    if (value.abs() < (cash ? 0.005 : 0.0005)) {
      return Text('—', style: TextStyle(color: theme.colorScheme.onSurfaceVariant));
    }
    final size = cash ? formatAmount(value.abs()) : formatGrams(value.abs());
    final color = value > 0 ? tones.debit.fg : tones.credit.fg;
    final settings = context.read<SettingsProvider>();
    final style = (large ? theme.textTheme.bodyLarge : theme.textTheme.bodyMedium)?.copyWith(
      fontWeight: FontWeight.w700,
      color: color,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        cash
            ? settings.buildText('${ltrIsolate(size)} ${settings.currencySymbolText}', style: style)
            : Text('${ltrIsolate(size)} جم', style: style),
        const SizedBox(width: 6),
        Text(
          value > 0 ? 'عليه' : 'له',
          style: theme.textTheme.labelMedium?.copyWith(color: color, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}
