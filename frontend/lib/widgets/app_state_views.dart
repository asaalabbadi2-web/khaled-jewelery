import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'app_feedback.dart';

/// UI-4 (ADR-049): what a list shows when it has no rows to show -- one look
/// for each of the three reasons, so that a user always knows which it is.
/// Taken from the statement's own (its test: «a failed load says so and
/// offers to try again -- not "no records"»).
///
/// - [AppLoadingView]: still loading -- the page's shape in grey, not a
///   spinner in the middle of nothing;
/// - [AppErrorView]: the load failed -- in the user's words, with «إعادة
///   المحاولة»; never shown as «no records»;
/// - [AppEmptyView]: loaded, and nothing is there -- why, and what to do.

/// The page's shape while it loads: [summaryBlocks] boxes across the top
/// (the totals), a bar (the filters), then [rows] lines.
class AppLoadingView extends StatelessWidget {
  const AppLoadingView({super.key, this.summaryBlocks = 3, this.rows = 6});

  final int summaryBlocks;
  final int rows;

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(
      context,
    ).colorScheme.surfaceContainerHighest.withValues(alpha: 0.7);
    Widget block(double height) => Container(
      height: height,
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
    );
    return Semantics(
      label: 'جارٍ التحميل',
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.lg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (summaryBlocks > 0) ...[
              Row(
                children: [
                  for (var i = 0; i < summaryBlocks; i++) ...[
                    if (i > 0) const SizedBox(width: AppSpace.md),
                    Expanded(child: block(92)),
                  ],
                ],
              ),
              const SizedBox(height: AppSpace.lg),
            ],
            block(52),
            const SizedBox(height: AppSpace.lg),
            for (var i = 0; i < rows; i++) ...[
              block(44),
              const SizedBox(height: AppSpace.sm),
            ],
            const SizedBox(height: AppSpace.xs),
            const LinearProgressIndicator(minHeight: 2),
          ],
        ),
      ),
    );
  }
}

/// A load that failed: [title] («تعذّر تحميل الكشف»), what went wrong in the
/// user's words ([error] through [AppFeedback.messageOf]), and a way back.
class AppErrorView extends StatelessWidget {
  const AppErrorView({
    super.key,
    required this.title,
    required this.error,
    required this.onRetry,
  });

  final String title;
  final Object? error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final said = error == null ? '' : AppFeedback.messageOf(error!);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 56,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: AppSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (said.isNotEmpty) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                said,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            const SizedBox(height: AppSpace.lg),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loaded, and nothing to show: [title] («لا توجد سندات مطابقة»), [hint]
/// (why, or what to change), and at most one [actionLabel] to act on it.
class AppEmptyView extends StatelessWidget {
  const AppEmptyView({
    super.key,
    required this.title,
    this.hint,
    this.icon = Icons.inbox_outlined,
    this.actionLabel,
    this.actionIcon,
    this.onAction,
  }) : assert((actionLabel == null) == (onAction == null));

  final String title;
  final String? hint;
  final IconData icon;
  final String? actionLabel;
  final IconData? actionIcon;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (hint != null) ...[
              const SizedBox(height: AppSpace.sm),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
            if (onAction != null) ...[
              const SizedBox(height: AppSpace.lg),
              FilledButton.tonalIcon(
                onPressed: onAction,
                icon: Icon(actionIcon ?? Icons.add),
                label: Text(actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
