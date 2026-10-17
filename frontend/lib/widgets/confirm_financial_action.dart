import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// UI-4 (ADR-049): the one dialog that confirms an act on the books that
/// cannot be taken back -- cancel, delete, reverse.
///
/// It says which document ([facts]: its number, its amount, its party), what
/// will happen to the books ([effect], in the server's terms), and, when a
/// reason is required ([reasonLabel]), keeps the confirm button off until one
/// is written -- the dialog used to close and only then say a reason was
/// required, and the reason was lost.
///
/// The way back is «تراجع», never «إلغاء»: «إلغاء» beside «إلغاء السند» was
/// one word for two opposite buttons.
///
/// Returns null when the user went back; otherwise the reason written ('' when
/// none was asked).
Future<String?> confirmFinancialAction(
  BuildContext context, {
  required String title,
  required String effect,
  required String confirmLabel,
  List<(String, String)> facts = const [],
  String? reasonLabel,
  bool destructive = true,
  String backLabel = 'تراجع',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _ConfirmFinancialActionDialog(
      title: title,
      effect: effect,
      confirmLabel: confirmLabel,
      facts: facts,
      reasonLabel: reasonLabel,
      destructive: destructive,
      backLabel: backLabel,
    ),
  );
}

class _ConfirmFinancialActionDialog extends StatefulWidget {
  const _ConfirmFinancialActionDialog({
    required this.title,
    required this.effect,
    required this.confirmLabel,
    required this.facts,
    required this.reasonLabel,
    required this.destructive,
    required this.backLabel,
  });

  final String title;
  final String effect;
  final String confirmLabel;
  final List<(String, String)> facts;
  final String? reasonLabel;
  final bool destructive;
  final String backLabel;

  @override
  State<_ConfirmFinancialActionDialog> createState() =>
      _ConfirmFinancialActionDialogState();
}

class _ConfirmFinancialActionDialogState
    extends State<_ConfirmFinancialActionDialog> {
  final _reason = TextEditingController();

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  bool get _ready =>
      widget.reasonLabel == null || _reason.text.trim().isNotEmpty;

  void _confirm() {
    if (!_ready) return;
    Navigator.of(context).pop(_reason.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tone = AppSemanticColors.of(context);
    final effectTone = widget.destructive ? tone.warning : tone.info;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (label, value) in widget.facts)
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpace.xs),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(label, style: theme.textTheme.bodyMedium),
                      ),
                      Text(
                        value,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              if (widget.facts.isNotEmpty) const SizedBox(height: AppSpace.sm),
              Container(
                key: const Key('confirm-effect'),
                padding: const EdgeInsets.all(AppSpace.md),
                decoration: BoxDecoration(
                  color: effectTone.container,
                  borderRadius: BorderRadius.circular(AppRadius.control),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      widget.destructive
                          ? Icons.warning_amber_rounded
                          : Icons.info_outline,
                      color: effectTone.onContainer,
                    ),
                    const SizedBox(width: AppSpace.sm),
                    Expanded(
                      child: Text(
                        widget.effect,
                        style: theme.textTheme.bodyLarge?.copyWith(
                          color: effectTone.onContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.reasonLabel != null) ...[
                const SizedBox(height: AppSpace.lg),
                TextField(
                  key: const Key('confirm-reason'),
                  controller: _reason,
                  autofocus: true,
                  maxLines: 3,
                  minLines: 1,
                  decoration: InputDecoration(
                    labelText: '${widget.reasonLabel} *',
                    helperText: 'مطلوب، ويُحفظ مع المستند.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(widget.backLabel),
        ),
        FilledButton(
          key: const Key('confirm-action'),
          onPressed: _ready ? _confirm : null,
          style: widget.destructive ? AppButtonStyles.danger(context) : null,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
