import 'package:flutter/material.dart';

import 'confirm_financial_action.dart';

/// UI-6 (ADR-049): a form asks before what was typed in it is lost -- by
/// back, by Esc, or by its own «إلغاء». The document screens each had their
/// own guard; the entry forms (customer, supplier, item, office, ...) had
/// none, and a slip of the back key threw a filled form away.
///
/// It reads the form's [controllers] as they were when it opened, and asks
/// only when one of them now says something else ([isDirty] adds what is not
/// a text: a picked date, a chosen type). A save leaves without asking: the
/// screen's own `Navigator.pop` after it does not come through here.
class AppLeaveGuard extends StatefulWidget {
  const AppLeaveGuard({
    super.key,
    required this.controllers,
    required this.child,
    this.isDirty,
  });

  final List<TextEditingController> controllers;
  final bool Function()? isDirty;
  final Widget child;

  @override
  State<AppLeaveGuard> createState() => _AppLeaveGuardState();
}

class _AppLeaveGuardState extends State<AppLeaveGuard> {
  /// The texts as the form opened -- taken here, not lazily: a lazy field
  /// would be read first when leaving, after the typing, and see no change.
  late final List<String> _opened;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _opened = [for (final c in widget.controllers) c.text];
  }

  bool get _changed =>
      (widget.isDirty?.call() ?? false) ||
      [
        for (var i = 0; i < widget.controllers.length; i++)
          widget.controllers[i].text != _opened[i],
      ].any((changed) => changed);

  Future<void> _onPop(bool didPop, Object? result) async {
    if (didPop || _leaving) return;
    if (_changed) {
      final leave = await confirmFinancialAction(
        context,
        title: 'الخروج دون حفظ؟',
        effect: 'ما كتبته في هذه الشاشة لم يُحفظ، ويضيع إن خرجت.',
        confirmLabel: 'الخروج دون حفظ',
        backLabel: 'البقاء',
      );
      if (leave == null || !mounted) return;
    }
    _leaving = true;
    if (mounted) Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: _onPop,
    child: widget.child,
  );
}
