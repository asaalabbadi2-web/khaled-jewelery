import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';

/// UI-6 (ADR-049): one keyboard across the app. The five document screens
/// (voucher, sale, purchase, scrap purchase, journal entry) each bound their
/// own Ctrl+S; now they share one place, and the same keys mean the same
/// thing everywhere:
///
/// - Ctrl/⌘+S       save (the screen decides whether it is ready)
/// - Ctrl/⌘+Enter   add a line, where a document has lines
/// - Esc            back -- through the screen's own leave guard, which asks
///                  when something typed would be lost
/// - F1             the list of the screen's keys
///
/// A list (vouchers, invoices, statement) has [AppListShortcuts]:
/// Ctrl/⌘+F to search, F5 to load again.

/// A key and what it does, as the help (F1) says it.
typedef ShortcutHelp = ({String keys, String what});

/// The keys of a document screen. Wrap the screen inside its PopScope.
class AppDocumentShortcuts extends StatelessWidget {
  const AppDocumentShortcuts({
    super.key,
    required this.onSave,
    required this.child,
    this.onAddLine,
    this.extra = const {},
    this.extraHelp = const [],
  });

  final VoidCallback onSave;
  final VoidCallback? onAddLine;

  /// The screen's own keys (e.g. Alt+1 … Alt+9 to pay), and how F1 says them.
  final Map<ShortcutActivator, VoidCallback> extra;
  final List<ShortcutHelp> extraHelp;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final help = <ShortcutHelp>[
      (keys: 'Ctrl+S', what: 'حفظ'),
      if (onAddLine != null) (keys: 'Ctrl+Enter', what: 'إضافة سطر'),
      ...extraHelp,
      (keys: 'Esc', what: 'رجوع (يسأل أولًا إن كان فيه ما لم يُحفظ)'),
      (keys: 'F1', what: 'هذه القائمة'),
    ];
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): onSave,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): onSave,
        if (onAddLine != null) ...{
          const SingleActivator(LogicalKeyboardKey.enter, control: true):
              onAddLine!,
          const SingleActivator(LogicalKeyboardKey.enter, meta: true):
              onAddLine!,
        },
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.maybePop(context),
        const SingleActivator(LogicalKeyboardKey.f1): () =>
            showShortcutsHelp(context, help),
        ...extra,
      },
      // A scope, so a field left with Enter hands focus back here, under the
      // keys -- not to the route, where Ctrl+S is not heard.
      child: FocusScope(autofocus: true, child: child),
    );
  }
}

/// The keys of a list screen: Ctrl/⌘+F puts the cursor in [searchFocus], F5
/// loads again, F1 says them. A list with no search (the clearing monitor)
/// has F5 and F1.
class AppListShortcuts extends StatelessWidget {
  const AppListShortcuts({
    super.key,
    required this.searchFocus,
    required this.onRefresh,
    required this.child,
  });

  final FocusNode? searchFocus;
  final VoidCallback onRefresh;
  final Widget child;

  static const help = <ShortcutHelp>[
    (keys: 'Ctrl+F', what: 'بحث'),
    (keys: 'F5', what: 'تحميل من جديد'),
    (keys: 'F1', what: 'هذه القائمة'),
  ];

  @override
  Widget build(BuildContext context) {
    final focus = searchFocus;
    void search() => focus?.requestFocus();
    return CallbackShortcuts(
      bindings: {
        if (focus != null) ...{
          const SingleActivator(LogicalKeyboardKey.keyF, control: true):
              search,
          const SingleActivator(LogicalKeyboardKey.keyF, meta: true): search,
        },
        const SingleActivator(LogicalKeyboardKey.f5): onRefresh,
        const SingleActivator(LogicalKeyboardKey.f1): () => showShortcutsHelp(
          context,
          focus == null ? help.skip(1).toList() : help,
        ),
      },
      child: FocusScope(autofocus: true, child: child),
    );
  }
}

/// The screen's keys, said: each key as it is pressed (left to right), and
/// what it does. «Ctrl» is «⌘» on a Mac.
Future<void> showShortcutsHelp(BuildContext context, List<ShortcutHelp> help) {
  final theme = Theme.of(context);
  final cs = theme.colorScheme;
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('اختصارات لوحة المفاتيح'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final h in help)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(h.what, style: theme.textTheme.bodyLarge),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpace.sm,
                        vertical: AppSpace.xs,
                      ),
                      decoration: BoxDecoration(
                        color: cs.surfaceContainerHigh,
                        borderRadius: BorderRadius.circular(AppRadius.chip),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      child: Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          h.keys,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpace.sm),
            Text('على الماك: ⌘ بدل Ctrl.', style: theme.textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إغلاق'),
        ),
      ],
    ),
  );
}
