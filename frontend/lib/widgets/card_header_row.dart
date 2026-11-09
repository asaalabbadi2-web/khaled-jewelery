import 'package:flutter/material.dart';

import '../theme/app_breakpoints.dart';

/// A card's header: its icon and title, then its buttons.
///
/// Beside the title on a tablet and a desk, as it was. Under it on a phone:
/// beside it they squeezed «بيانات المورد» and «إدخال سريع» to a word a line
/// on an iPhone (the owner, 9 Nov 2026).
class CardHeaderRow extends StatelessWidget {
  const CardHeaderRow({
    super.key,
    required this.lead,
    required this.actions,
    this.crossAxisAlignment = CrossAxisAlignment.center,
  });

  /// The icon and the title; the title is the one [Expanded].
  final List<Widget> lead;

  /// The buttons, with their own spacing.
  final List<Widget> actions;

  final CrossAxisAlignment crossAxisAlignment;

  @override
  Widget build(BuildContext context) {
    if (!AppBreakpoints.isPhone(context)) {
      return Row(
        crossAxisAlignment: crossAxisAlignment,
        children: [...lead, ...actions],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(crossAxisAlignment: crossAxisAlignment, children: lead),
        const SizedBox(height: 10),
        Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          runSpacing: 8,
          children: actions,
        ),
      ],
    );
  }
}
