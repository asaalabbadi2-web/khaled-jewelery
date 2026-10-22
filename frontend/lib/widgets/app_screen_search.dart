import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../utils/arabic_search.dart';

/// ADR-057 ق٠: one search for the app's screens, in the home screen's header
/// (the owner, 22 Oct 2026: «الشاشات ليست كلها موجودة في القائمة الجانبية»
/// and «يُفضَّل أن يكون هناك حقل بحث في هيدر الشاشة الرئيسية»).
///
/// It finds a screen by its name, its section and the words people use for it
/// ([ScreenDestination.keywords] -- «ضريبة» finds the VAT returns), written as
/// people write them (`normalizeForSearch`). The screens are the side menu's,
/// the reports catalog's and those that open on their own from elsewhere --
/// the caller builds them, holding only what the user may open.

/// A screen the search can open.
class ScreenDestination {
  const ScreenDestination({
    required this.title,
    required this.section,
    required this.icon,
    required this.open,
    this.keywords = const [],
  });

  final String title;
  final String section;
  final IconData icon;
  final List<String> keywords;
  final Future<void> Function() open;
}

/// The destinations [query] finds, best first: a title that starts with it,
/// then a title that holds it, then its section or its words.
List<ScreenDestination> matchDestinations(
  List<ScreenDestination> all,
  String query,
) {
  final q = normalizeForSearch(query);
  if (q.isEmpty) return const [];
  final ranked = <(int, int, ScreenDestination)>[];
  for (var i = 0; i < all.length; i++) {
    final d = all[i];
    final title = normalizeForSearch(d.title);
    final int rank;
    if (title.startsWith(q)) {
      rank = 0;
    } else if (title.contains(q)) {
      rank = 1;
    } else if ([
      d.section,
      ...d.keywords,
    ].any((w) => normalizeForSearch(w).contains(q))) {
      rank = 2;
    } else {
      continue;
    }
    ranked.add((rank, i, d));
  }
  ranked.sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  // One screen once: the menu and the reports may both hold it (the trial
  // balance) -- the first, the menu's, is the one shown.
  final seen = <String>{};
  return [
    for (final r in ranked)
      if (seen.add(normalizeForSearch(r.$3.title))) r.$3,
  ];
}

/// The screens last opened from the search, on this device -- a convenience of
/// the one who uses it, not a record.
abstract final class RecentScreens {
  static const _key = 'screen_search_recent';
  static const _keep = 6;

  static Future<List<String>> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_key) ?? const [];
    } catch (_) {
      return const [];
    }
  }

  static Future<void> add(String title) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = [
        title,
        ...(prefs.getStringList(_key) ?? const <String>[]).where(
          (t) => t != title,
        ),
      ].take(_keep).toList();
      await prefs.setStringList(_key, now);
    } catch (_) {}
  }
}

/// Opens the search over [destinations]: a dialog on a wide screen, the whole
/// screen on a phone. ↑ ↓ choose, Enter opens, Esc closes.
Future<void> showScreenSearch(
  BuildContext context,
  List<ScreenDestination> destinations,
) async {
  final recent = await RecentScreens.load();
  if (!context.mounted) return;
  final wide = MediaQuery.sizeOf(context).width >= 700;
  final chosen = await showDialog<ScreenDestination>(
    context: context,
    builder: (_) => _ScreenSearchDialog(
      destinations: destinations,
      recent: recent,
      fullscreen: !wide,
    ),
  );
  if (chosen == null) return;
  await RecentScreens.add(chosen.title);
  await chosen.open();
}

class _ScreenSearchDialog extends StatefulWidget {
  const _ScreenSearchDialog({
    required this.destinations,
    required this.recent,
    required this.fullscreen,
  });

  final List<ScreenDestination> destinations;
  final List<String> recent;
  final bool fullscreen;

  @override
  State<_ScreenSearchDialog> createState() => _ScreenSearchDialogState();
}

class _ScreenSearchDialogState extends State<_ScreenSearchDialog> {
  final _query = TextEditingController();
  int _selected = 0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<ScreenDestination> get _shown {
    if (_query.text.trim().isEmpty) {
      return [
        for (final title in widget.recent)
          ...widget.destinations.where((d) => d.title == title).take(1),
      ];
    }
    return matchDestinations(widget.destinations, _query.text);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final shown = _shown;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown && shown.isNotEmpty) {
      setState(() => _selected = (_selected + 1) % shown.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && shown.isNotEmpty) {
      setState(
        () => _selected = (_selected - 1 + shown.length) % shown.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter && shown.isNotEmpty) {
      Navigator.of(context).pop(shown[_selected.clamp(0, shown.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shown = _shown;
    final empty = _query.text.trim().isEmpty;

    final field = Focus(
      onKeyEvent: _onKey,
      child: TextField(
        key: const Key('screen-search-field'),
        controller: _query,
        autofocus: true,
        textInputAction: TextInputAction.go,
        onChanged: (_) => setState(() => _selected = 0),
        decoration: InputDecoration(
          prefixIcon: const Icon(Icons.search),
          hintText: 'ابحث عن شاشة: فاتورة، كشف، ضريبة…',
          suffixIcon: IconButton(
            tooltip: 'إغلاق',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );

    final Widget results;
    if (shown.isEmpty) {
      results = Padding(
        padding: const EdgeInsets.all(AppSpace.xl),
        child: Text(
          empty
              ? 'اكتب اسم الشاشة أو كلمة منها.'
              : 'لا شاشة بهذا الاسم. جرّب كلمة أخرى.',
          key: const Key('screen-search-empty'),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
          ),
        ),
      );
    } else {
      results = ListView.builder(
        shrinkWrap: !widget.fullscreen,
        itemCount: shown.length + (empty ? 1 : 0),
        itemBuilder: (context, i) {
          if (empty && i == 0) {
            return Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(
                AppSpace.lg,
                AppSpace.md,
                AppSpace.lg,
                AppSpace.xs,
              ),
              child: Text(
                'آخر ما فتحته',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            );
          }
          final index = empty ? i - 1 : i;
          final d = shown[index];
          final selected = index == _selected;
          return ListTile(
            key: Key('screen-search-result-$index'),
            selected: selected,
            selectedTileColor: cs.secondaryContainer,
            leading: Icon(d.icon),
            title: Text(d.title),
            subtitle: Text(
              d.section,
              style: theme.textTheme.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
            onTap: () => Navigator.of(context).pop(d),
          );
        },
      );
    }

    final body = Column(
      mainAxisSize: widget.fullscreen ? MainAxisSize.max : MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(padding: const EdgeInsets.all(AppSpace.md), child: field),
        if (widget.fullscreen)
          Expanded(child: results)
        else
          Flexible(child: results),
      ],
    );

    if (widget.fullscreen) {
      return Dialog.fullscreen(child: SafeArea(child: body));
    }
    return Dialog(
      alignment: Alignment.topCenter,
      insetPadding: const EdgeInsets.only(top: 72, left: 24, right: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
        child: body,
      ),
    );
  }
}

/// The header's search: a field on a wide screen, an icon on a phone. Both
/// open [showScreenSearch]; Ctrl/⌘+K does too (bound by the screen).
class ScreenSearchButton extends StatelessWidget {
  const ScreenSearchButton({
    super.key,
    required this.onOpen,
    required this.foreground,
  });

  final VoidCallback onOpen;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (MediaQuery.sizeOf(context).width < 700) {
      return IconButton(
        key: const Key('screen-search-open'),
        tooltip: 'ابحث عن شاشة (Ctrl+K)',
        icon: Icon(Icons.search, color: foreground),
        onPressed: onOpen,
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Material(
        key: const Key('screen-search-open'),
        color: foreground.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppRadius.pill),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.pill),
          onTap: onOpen,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.sm,
            ),
            child: Row(
              children: [
                Icon(Icons.search, size: 20, color: foreground),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    'ابحث عن شاشة…',
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: foreground.withValues(alpha: 0.85),
                    ),
                  ),
                ),
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    'Ctrl+K',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: foreground.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
