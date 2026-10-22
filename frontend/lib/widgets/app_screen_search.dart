import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/app_theme.dart';
import '../utils/arabic_search.dart';

/// ADR-057 ق٠: one search for the app's screens, in the home screen's header
/// (the owner, 22 Oct 2026: «الشاشات ليست كلها موجودة في القائمة الجانبية»
/// and «يُفضَّل أن يكون هناك حقل بحث في هيدر الشاشة الرئيسية»). One types in
/// the header's field itself, and the results drop under it on the same
/// screen, over the page dimmed and blurred -- not in a window of their own
/// (the owner: «في نفس الحقل … قائمة منسدلة بخلفية مائية بنفس الشاشة وليس
/// نافذة منبثقة»).
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

/// The header's search: on a wide screen a field one types in, its results
/// dropping under it; on a phone an icon that turns the header into the field.
/// Either way the page behind is dimmed and blurred, and a tap on it closes.
/// ↑ ↓ choose, Enter opens, Esc closes; [ScreenSearchBarState.open] is what
/// Ctrl/⌘+K calls (bound by the screen).
class ScreenSearchBar extends StatefulWidget {
  const ScreenSearchBar({
    super.key,
    required this.destinations,
    required this.foreground,
  });

  /// Built when the search opens: what the user may open now.
  final List<ScreenDestination> Function() destinations;

  /// The header's text colour.
  final Color foreground;

  @override
  State<ScreenSearchBar> createState() => ScreenSearchBarState();
}

class ScreenSearchBarState extends State<ScreenSearchBar> {
  final _link = LayerLink();
  final _portal = OverlayPortalController();
  final _query = TextEditingController();
  final _focus = FocusNode();
  List<ScreenDestination> _all = const [];
  List<String> _recent = const [];
  int _selected = 0;

  /// Where the page under the header starts, for the dimmed backdrop.
  double _below = 0;

  bool get _compact => MediaQuery.sizeOf(context).width < 700;

  @override
  void dispose() {
    _query.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Opens the results (recent, until something is typed) and puts the cursor
  /// in the field.
  Future<void> open() async {
    if (_portal.isShowing) {
      _focus.requestFocus();
      return;
    }
    _all = widget.destinations();
    final box = context.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final rect = box.localToGlobal(Offset.zero) & box.size;
      // The field sits in the middle of the header: its bottom edge is as far
      // below the field as its top is above.
      _below = rect.bottom + math.max(0.0, (kToolbarHeight - rect.height) / 2);
    }
    _recent = await RecentScreens.load();
    if (!mounted) return;
    setState(() => _selected = 0);
    _portal.show();
    _focus.requestFocus();
  }

  void close() {
    if (!_portal.isShowing) return;
    _portal.hide();
    _query.clear();
    _focus.unfocus();
    setState(() {});
  }

  Future<void> _choose(ScreenDestination d) async {
    close();
    await RecentScreens.add(d.title);
    await d.open();
  }

  List<ScreenDestination> get _shown {
    if (_query.text.trim().isEmpty) {
      return [
        for (final title in _recent)
          ..._all.where((d) => d.title == title).take(1),
      ];
    }
    return matchDestinations(_all, _query.text);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_portal.isShowing) return KeyEventResult.ignored;
      close();
      return KeyEventResult.handled;
    }
    final shown = _shown;
    if (!_portal.isShowing || shown.isEmpty) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _selected = (_selected + 1) % shown.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(
        () => _selected = (_selected - 1 + shown.length) % shown.length,
      );
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _choose(shown[_selected.clamp(0, shown.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _changed(String _) {
    setState(() => _selected = 0);
    if (!_portal.isShowing) open();
  }

  /// The field: in the header on a wide screen, atop the page on a phone.
  Widget _field({required Color foreground, required bool inHeader}) {
    final theme = Theme.of(context);
    final typing = _query.text.isNotEmpty;
    return Focus(
      onKeyEvent: _onKey,
      child: TextField(
        key: const Key('screen-search-field'),
        controller: _query,
        focusNode: _focus,
        autofocus: !inHeader,
        onTap: open,
        onChanged: _changed,
        onTapOutside: (_) {},
        cursorColor: foreground,
        textAlignVertical: TextAlignVertical.center,
        style: theme.textTheme.bodyMedium?.copyWith(color: foreground),
        textInputAction: TextInputAction.go,
        decoration: InputDecoration(
          isDense: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          hintText: inHeader
              ? 'ابحث عن شاشة…'
              : 'ابحث عن شاشة: فاتورة، كشف، ضريبة…',
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: foreground.withValues(alpha: 0.8),
          ),
          prefixIcon: Icon(Icons.search, size: 20, color: foreground),
          prefixIconConstraints: const BoxConstraints(minWidth: 36),
          suffixIcon: typing || !inHeader
              ? IconButton(
                  tooltip: typing ? 'مسح' : 'إغلاق',
                  icon: Icon(Icons.close, size: 20, color: foreground),
                  onPressed: typing
                      ? () {
                          _query.clear();
                          _changed('');
                        }
                      : close,
                )
              : Padding(
                  padding: const EdgeInsetsDirectional.only(end: AppSpace.md),
                  child: Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      'Ctrl+K',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: foreground.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
          suffixIconConstraints: const BoxConstraints(minHeight: 32),
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpace.md),
        ),
      ),
    );
  }

  Widget _results() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final shown = _shown;
    final empty = _query.text.trim().isEmpty;
    if (shown.isEmpty) {
      return Padding(
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
    }
    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      itemCount: shown.length + (empty ? 1 : 0),
      itemBuilder: (context, i) {
        if (empty && i == 0) {
          return Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(
              AppSpace.lg,
              AppSpace.sm,
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
        return ListTile(
          key: Key('screen-search-result-$index'),
          selected: index == _selected,
          selectedTileColor: cs.secondaryContainer,
          leading: Icon(d.icon),
          title: Text(d.title),
          subtitle: Text(
            d.section,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
          onTap: () => _choose(d),
        );
      },
    );
  }

  /// The page behind: dimmed and blurred; a tap on it closes the search.
  Widget _backdrop() {
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(
      key: const Key('screen-search-backdrop'),
      behavior: HitTestBehavior.opaque,
      onTap: close,
      child: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
          child: ColoredBox(color: cs.scrim.withValues(alpha: 0.3)),
        ),
      ),
    );
  }

  Widget _panel({required BorderRadius radius, required double maxHeight}) {
    final cs = Theme.of(context).colorScheme;
    return TextFieldTapRegion(
      child: Material(
        key: const Key('screen-search-panel'),
        color: cs.surfaceContainerLow,
        elevation: 6,
        borderRadius: radius,
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: _results(),
        ),
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final size = MediaQuery.sizeOf(context);
    if (_compact) {
      // A phone: the header becomes the field; the results drop under it.
      return Stack(
        children: [
          Positioned.fill(child: _backdrop()),
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFieldTapRegion(
                child: Material(
                  color: cs.surfaceContainerHigh,
                  child: SafeArea(
                    bottom: false,
                    child: SizedBox(
                      height: kToolbarHeight,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.sm,
                        ),
                        child: Center(
                          child: _field(
                            foreground: cs.onSurface,
                            inHeader: false,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Flexible(
                child: _panel(
                  radius: const BorderRadius.vertical(
                    bottom: Radius.circular(AppRadius.card),
                  ),
                  maxHeight: size.height,
                ),
              ),
            ],
          ),
        ],
      );
    }
    // Wider than the field, so a report's long name reads whole.
    final width = math.min(size.width - 2 * AppSpace.lg, 520.0);
    return Stack(
      children: [
        Positioned(
          top: _below,
          left: 0,
          right: 0,
          bottom: 0,
          child: _backdrop(),
        ),
        CompositedTransformFollower(
          link: _link,
          targetAnchor: Alignment.bottomCenter,
          followerAnchor: Alignment.topCenter,
          offset: const Offset(0, AppSpace.sm),
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: _panel(
                radius: BorderRadius.circular(AppRadius.card),
                maxHeight: math.min(460.0, size.height - _below - AppSpace.xl),
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget anchor;
    if (_compact) {
      anchor = IconButton(
        key: const Key('screen-search-open'),
        tooltip: 'ابحث عن شاشة (Ctrl+K)',
        icon: Icon(Icons.search, color: widget.foreground),
        onPressed: open,
      );
    } else {
      anchor = ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Material(
          key: const Key('screen-search-open'),
          color: widget.foreground.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadius.pill),
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: AppSpace.xs),
            child: _field(foreground: widget.foreground, inHeader: true),
          ),
        ),
      );
    }
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _portal,
        overlayChildBuilder: _overlay,
        child: anchor,
      ),
    );
  }
}
