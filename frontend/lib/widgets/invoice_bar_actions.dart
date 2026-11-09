import 'package:flutter/material.dart';

import '../theme/app_breakpoints.dart';

/// An invoice's title bar actions as the device has room for them. On a
/// phone the title comes first («فاتورة شرا...» was cut on an iPhone, 9 Nov
/// 2026): the user's name is not shown (the user knows it), the actions it
/// [keep]s stay buttons, and those it may [fold] go under «⋮» -- each read
/// from its own button: its icon, its words, what it does. Wider, all as
/// they were.
List<Widget> invoiceBarActions(
  BuildContext context, {
  Widget? user,
  List<Widget> keep = const [],
  List<IconButton> fold = const [],
}) {
  if (!AppBreakpoints.isPhone(context)) {
    return [if (user != null) user, ...keep, ...fold];
  }
  return [
    ...keep,
    if (fold.isNotEmpty)
      PopupMenuButton<int>(
        key: const Key('invoice-bar-more'),
        tooltip: 'المزيد',
        icon: const Icon(Icons.more_vert),
        onSelected: (i) => fold[i].onPressed?.call(),
        itemBuilder: (_) => [
          for (var i = 0; i < fold.length; i++)
            PopupMenuItem<int>(
              value: i,
              enabled: fold[i].onPressed != null,
              child: Row(
                children: [
                  fold[i].icon,
                  const SizedBox(width: 12),
                  Flexible(child: Text(fold[i].tooltip ?? '', overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
        ],
      ),
  ];
}
