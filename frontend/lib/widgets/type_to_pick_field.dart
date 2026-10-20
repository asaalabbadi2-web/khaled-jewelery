import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// A field found by typing in it (the owner, 20 Oct 2026: «أليس من الأسهل
/// والأسرع الكتابة والبحث في الحقل نفسه مع إتاحة إظهار القائمة؟»).
///
/// Typing narrows the matches under the field; the arrows move among them,
/// Enter takes one and Tab moves on, so a form is filled from the keyboard. A button at its end opens the whole list for whoever
/// would rather browse. Left half-typed, it shows again what was chosen.
class TypeToPickField extends StatefulWidget {
  const TypeToPickField({
    super.key,
    required this.items,
    required this.selectedId,
    required this.labelOf,
    required this.onSelected,
    this.searchTextOf,
    this.subtitleOf,
    this.onShowAll,
    this.fieldKey,
    this.showAllKey,
    this.labelText,
    this.hintText,
    this.helperText,
    this.prefixIcon,
    this.enabled = true,
    this.maxOptions = 50,
  });

  final List<Map<String, dynamic>> items;
  final int? selectedId;
  final String Function(Map<String, dynamic> item) labelOf;

  /// What a match is searched in; its label when none is given.
  final String Function(Map<String, dynamic> item)? searchTextOf;

  /// A match's second line: its code, what it holds.
  final String? Function(Map<String, dynamic> item)? subtitleOf;
  final ValueChanged<Map<String, dynamic>> onSelected;

  /// Opens the whole list; no button without it.
  final VoidCallback? onShowAll;
  final Key? fieldKey;
  final Key? showAllKey;
  final String? labelText;
  final String? hintText;
  final String? helperText;
  final IconData? prefixIcon;
  final bool enabled;
  final int maxOptions;

  @override
  State<TypeToPickField> createState() => _TypeToPickFieldState();
}

class _TypeToPickFieldState extends State<TypeToPickField> {
  final _controller = TextEditingController();
  final _focus = FocusNode();

  /// The list button is out of the Tab order: from the keyboard one types.
  final _showAllFocus = FocusNode(skipTraversal: true);
  double _width = 320;

  static int? _idOf(Map<String, dynamic> item) {
    final raw = item['id'];
    return raw is int ? raw : (raw is num ? raw.toInt() : int.tryParse('$raw'));
  }

  Map<String, dynamic>? get _selected {
    for (final item in widget.items) {
      if (_idOf(item) == widget.selectedId) return item;
    }
    return null;
  }

  String get _selectedLabel {
    final item = _selected;
    return item == null ? '' : widget.labelOf(item);
  }

  @override
  void initState() {
    super.initState();
    _controller.text = _selectedLabel;
    _focus.addListener(() {
      if (_focus.hasFocus) {
        // Typing replaces what is shown: the whole text is taken on focus.
        _controller.selection = TextSelection(
          baseOffset: 0,
          extentOffset: _controller.text.length,
        );
      } else if (_controller.text != _selectedLabel) {
        _controller.text = _selectedLabel;
      }
    });
  }

  @override
  void didUpdateWidget(TypeToPickField old) {
    super.didUpdateWidget(old);
    if (!_focus.hasFocus && _controller.text != _selectedLabel) {
      _controller.text = _selectedLabel;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    _showAllFocus.dispose();
    super.dispose();
  }

  /// Everything, until something other than the choice is typed. Shown
  /// only while the field has the focus.
  Iterable<Map<String, dynamic>> _matches(TextEditingValue value) {
    final q = value.text.trim().toLowerCase();
    if (q.isEmpty || value.text == _selectedLabel) {
      return widget.items.take(widget.maxOptions);
    }
    final search = widget.searchTextOf ?? widget.labelOf;
    return widget.items
        .where((item) => search(item).toLowerCase().contains(q))
        .take(widget.maxOptions);
  }

  /// Taken, the field keeps the focus: Tab moves on. Moving it for them
  /// landed on the app bar's back in a right-to-left two-column page, where
  /// the next Enter left the screen.
  void _take(Map<String, dynamic> item) {
    _controller.text = widget.labelOf(item);
    widget.onSelected(item);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        _width = box.maxWidth;
        return RawAutocomplete<Map<String, dynamic>>(
          textEditingController: _controller,
          focusNode: _focus,
          optionsBuilder: _matches,
          displayStringForOption: widget.labelOf,
          onSelected: _take,
          fieldViewBuilder: (context, controller, focus, onSubmitted) => TextField(
            key: widget.fieldKey,
            controller: controller,
            focusNode: focus,
            enabled: widget.enabled,
            onSubmitted: (_) => onSubmitted(),
            // Enter takes a match and the focus stays (a field lets it go).
            onEditingComplete: () {},
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              helperText: widget.helperText,
              border: const OutlineInputBorder(),
              prefixIcon: widget.prefixIcon == null ? null : Icon(widget.prefixIcon),
              suffixIcon: widget.onShowAll == null
                  ? null
                  : IconButton(
                      key: widget.showAllKey,
                      focusNode: _showAllFocus,
                      tooltip: 'عرض القائمة كاملة',
                      icon: const Icon(Icons.list_alt),
                      onPressed: widget.enabled ? widget.onShowAll : null,
                    ),
            ),
          ),
          optionsViewBuilder: (context, onSelected, options) {
            final highlighted = AutocompleteHighlightedOption.of(context);
            final list = options.toList();
            return Align(
              alignment: AlignmentDirectional.topStart,
              child: Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(AppRadius.control),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: 320, maxWidth: _width),
                  child: ListView.builder(
                    padding: EdgeInsets.zero,
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final item = list[i];
                      final subtitle = widget.subtitleOf?.call(item);
                      final lit = i == highlighted;
                      if (lit) {
                        // The highlighted match stays in sight as the arrows move.
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (context.mounted) Scrollable.ensureVisible(context);
                        });
                      }
                      return ListTile(
                        key: Key('type-to-pick-option-${_idOf(item)}'),
                        dense: true,
                        selected: lit,
                        selectedTileColor: theme.colorScheme.primary.withValues(alpha: 0.08),
                        title: Text(widget.labelOf(item)),
                        subtitle: subtitle == null ? null : Text(subtitle),
                        onTap: () => onSelected(item),
                      );
                    },
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
