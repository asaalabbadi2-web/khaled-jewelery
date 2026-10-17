import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// UI-4 (ADR-049): a list's table -- the frame the vouchers and invoices
/// lists each built, and the widths all three lists (the statement too)
/// worked out on their own.
///
/// The widths come from the room the table is given, not from the screen: two
/// of the three took the screen's width less a guessed margin, so a table in
/// a side panel or an embedded list was sized for a room it did not have.

/// A column: its least [width], and its [grow] -- its share of the room the
/// columns leave spare (0: it keeps its width).
@immutable
class AppTableColumn {
  const AppTableColumn(this.width, {this.grow = 0});

  final double width;
  final double grow;
}

/// Each column's width in [available] room, and the table's width: every
/// column its least; what is spare shared by `grow`. When the columns need
/// more than there is, the table is wider than the room and scrolls.
({Map<String, double> widths, double width}) fitTableColumns(
  Map<String, AppTableColumn> columns,
  double available,
) {
  final least = columns.values.fold<double>(0, (sum, c) => sum + c.width);
  final grows = columns.values.fold<double>(0, (sum, c) => sum + c.grow);
  final spare = available.isFinite ? available - least : 0.0;
  final widths = {
    for (final MapEntry(:key, value: c) in columns.entries)
      key: c.width + (spare > 0 && grows > 0 ? spare * c.grow / grows : 0),
  };
  final width = spare > 0 && grows > 0 ? available : least;
  return (widths: widths, width: width);
}

/// The frame of a list's table: a header that stays while [rowCount] rows
/// scroll beneath it, the whole sliding sideways when the room is narrower
/// than the columns, with its scrollbar in sight; pull down to refresh.
class AppTableFrame extends StatefulWidget {
  const AppTableFrame({
    super.key,
    required this.columns,
    required this.header,
    required this.rowCount,
    required this.row,
    required this.onRefresh,
    this.horizontalController,
  });

  final Map<String, AppTableColumn> columns;
  final Widget Function(Map<String, double> widths) header;
  final int rowCount;
  final Widget Function(
    BuildContext context,
    int index,
    Map<String, double> widths,
  )
  row;
  final Future<void> Function() onRefresh;

  /// The sideways scroll; one of its own when none is given (the rows'
  /// scroll is the primary one, and a scrollbar must not take it).
  final ScrollController? horizontalController;

  @override
  State<AppTableFrame> createState() => _AppTableFrameState();
}

class _AppTableFrameState extends State<AppTableFrame> {
  ScrollController? _own;

  ScrollController get _horizontal =>
      widget.horizontalController ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final columns = widget.columns;
    return LayoutBuilder(
      builder: (context, constraints) {
        final fit = fitTableColumns(columns, constraints.maxWidth);
        final height = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : 480.0;
        return DecoratedBox(
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadius.card),
            child: Scrollbar(
              controller: _horizontal,
              thumbVisibility: fit.width > constraints.maxWidth,
              notificationPredicate: (n) => n.metrics.axis == Axis.horizontal,
              child: SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                  key: const Key('app-table'),
                  width: fit.width,
                  height: height,
                  child: Column(
                    children: [
                      widget.header(fit.widths),
                      Expanded(
                        child: RefreshIndicator(
                          onRefresh: widget.onRefresh,
                          child: ListView.builder(
                            primary: true,
                            padding: EdgeInsets.zero,
                            physics: const AlwaysScrollableScrollPhysics(),
                            itemCount: widget.rowCount,
                            itemBuilder: (context, i) =>
                                widget.row(context, i, fit.widths),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
