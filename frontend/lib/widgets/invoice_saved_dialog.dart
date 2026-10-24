import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/currency_utils.dart';
import '../utils/invoice_saved_facts.dart';

/// ADR-060 ف٢: what is said once an invoice is saved -- short, and all of it
/// the server's (InvoiceSavedFacts): its number, to copy; where it stands
/// (posted, awaiting posting, or held for the manager, and why); what it came
/// to, what was paid and what remains. Then what to do next: print, share, a
/// new invoice, or done.
///
/// P prints, N starts a new invoice, Enter and Esc are done.

enum InvoiceSavedAction { print, share, newInvoice, done }

class InvoiceSaved {
  const InvoiceSaved({
    required this.title,
    required this.facts,
    required this.currency,
    this.partyLabel = 'العميل',
    this.party = '',
    this.held = const [],
  });

  /// «حُفظت فاتورة بيع».
  final String title;
  final InvoiceSavedFacts facts;
  final String currency;
  final String partyLabel;
  final String party;

  /// Why the manager holds it, in the server's terms -- empty when it is not
  /// held.
  final List<String> held;
}

Future<InvoiceSavedAction> showInvoiceSaved(
  BuildContext context,
  InvoiceSaved saved,
) async {
  // The screen's direction, as the review (ADR-060 ف١).
  final direction = Directionality.of(context);
  final action = await showGeneralDialog<InvoiceSavedAction>(
    context: context,
    barrierDismissible: false,
    barrierLabel: saved.title,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => Directionality(
      textDirection: direction,
      child: _InvoiceSavedDialog(saved: saved),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
  return action ?? InvoiceSavedAction.done;
}

class _InvoiceSavedDialog extends StatefulWidget {
  const _InvoiceSavedDialog({required this.saved});

  final InvoiceSaved saved;

  @override
  State<_InvoiceSavedDialog> createState() => _InvoiceSavedDialogState();
}

class _InvoiceSavedDialogState extends State<_InvoiceSavedDialog> {
  bool _copied = false;

  InvoiceSaved get s => widget.saved;

  void _close(InvoiceSavedAction a) => Navigator.of(context).pop(a);

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: s.facts.number));
    if (mounted) setState(() => _copied = true);
  }

  Widget _figure(String text, {TextStyle? style}) {
    final base = style ?? Theme.of(context).textTheme.bodyLarge;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Text(
        text,
        style: base?.copyWith(
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _amount(double v, {TextStyle? style}) {
    final base = style ?? Theme.of(context).textTheme.bodyLarge;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _figure(formatAmount(v), style: base),
        const SizedBox(width: AppSpace.xs),
        Text(s.currency, style: base?.copyWith(fontWeight: FontWeight.w400)),
      ],
    );
  }

  Widget _kv(String label, Widget value, {bool strong = false}) {
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: (strong ? t.titleLarge : t.bodyLarge)?.copyWith(
                fontWeight: strong ? FontWeight.w700 : null,
              ),
            ),
          ),
          value,
        ],
      ),
    );
  }

  Widget _keyHint(String key, Color color) => Container(
    margin: const EdgeInsetsDirectional.only(start: AppSpace.sm),
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
    decoration: BoxDecoration(
      border: Border.all(color: color.withValues(alpha: 0.5)),
      borderRadius: BorderRadius.circular(AppRadius.chip),
    ),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Text(
        key,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = theme.textTheme;
    final tones = AppSemanticColors.of(context);
    final phone = MediaQuery.sizeOf(context).width < 700;
    final size = MediaQuery.sizeOf(context);
    final facts = s.facts;
    final held = s.held.isNotEmpty;

    // Where it stands: held for the manager, posted, or awaiting posting.
    final (SemanticTone standTone, IconData standIcon, String stand) = held
        ? (tones.warning, Icons.hourglass_top_rounded, 'تنتظر اعتماد المدير')
        : facts.posted
        ? (tones.ready, Icons.task_alt_rounded, 'مرحَّلة')
        : (tones.info, Icons.schedule_rounded, 'محفوظة، تنتظر الترحيل');

    Widget action(
      InvoiceSavedAction a,
      IconData icon,
      String label, {
      String? key,
    }) => Expanded(
      child: OutlinedButton(
        key: Key('invoice-saved-${a.name}'),
        onPressed: () => _close(a),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: AppSpace.xs),
            Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            if (key != null && !phone) _keyHint(key, cs.onSurfaceVariant),
          ],
        ),
      ),
    );

    final card = Material(
      key: const Key('invoice-saved'),
      color: cs.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: phone
            ? const BorderRadius.vertical(top: Radius.circular(AppRadius.card))
            : BorderRadius.circular(AppRadius.card),
        side: BorderSide(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: phone ? size.width : 560,
          maxHeight: size.height * 0.92,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(
                  AppSpace.lg,
                  AppSpace.lg,
                  AppSpace.lg,
                  AppSpace.md,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: tones.ready.container,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: 32,
                          color: tones.ready.onContainer,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Text(
                      s.title,
                      textAlign: TextAlign.center,
                      style: t.headlineMedium,
                    ),
                    const SizedBox(height: AppSpace.xs),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _figure(
                          facts.number,
                          style: t.headlineSmall?.copyWith(letterSpacing: 0.5),
                        ),
                        IconButton(
                          key: const Key('invoice-saved-copy'),
                          tooltip: _copied ? 'نُسخ الرقم' : 'نسخ الرقم',
                          onPressed: _copy,
                          icon: Icon(
                            _copied ? Icons.check_rounded : Icons.copy_rounded,
                            size: 18,
                            color: cs.primary,
                          ),
                        ),
                      ],
                    ),
                    Center(
                      child: Container(
                        key: const Key('invoice-saved-stand'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpace.md,
                          vertical: AppSpace.xs,
                        ),
                        decoration: BoxDecoration(
                          color: standTone.container,
                          borderRadius: BorderRadius.circular(AppRadius.pill),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              standIcon,
                              size: 16,
                              color: standTone.onContainer,
                            ),
                            const SizedBox(width: AppSpace.xs),
                            Text(
                              stand,
                              style: t.labelLarge?.copyWith(
                                color: standTone.onContainer,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    for (final why in s.held)
                      Padding(
                        padding: const EdgeInsets.only(top: AppSpace.xs),
                        child: Text(
                          why,
                          textAlign: TextAlign.center,
                          style: t.bodyMedium?.copyWith(
                            color: tones.warning.fg,
                          ),
                        ),
                      ),
                    const SizedBox(height: AppSpace.md),
                    Container(
                      padding: const EdgeInsets.all(AppSpace.md),
                      decoration: BoxDecoration(
                        color: cs.surface,
                        borderRadius: BorderRadius.circular(AppRadius.control),
                        border: Border.all(color: cs.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          if (s.party.isNotEmpty)
                            _kv(s.partyLabel, Text(s.party, style: t.bodyLarge)),
                          _kv(
                            'الإجمالي',
                            _amount(facts.total, style: t.titleLarge),
                            strong: true,
                          ),
                          _kv('المدفوع', _amount(facts.paid)),
                          Container(
                            key: const Key('invoice-saved-payment'),
                            margin: const EdgeInsets.only(top: AppSpace.xs),
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpace.md,
                              vertical: AppSpace.xs,
                            ),
                            decoration: BoxDecoration(
                              color: facts.owes
                                  ? tones.blocked.container
                                  : tones.ready.container,
                              borderRadius: BorderRadius.circular(
                                AppRadius.control,
                              ),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    facts.statusLine(
                                      (v) => '${formatAmount(v)} ${s.currency}',
                                    ),
                                    style: t.bodyLarge?.copyWith(
                                      color: facts.owes
                                          ? tones.blocked.onContainer
                                          : tones.ready.onContainer,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(top: BorderSide(color: cs.outlineVariant)),
              ),
              child: Padding(
                padding: const EdgeInsets.all(AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    FilledButton.icon(
                      key: const Key('invoice-saved-print'),
                      onPressed: () => _close(InvoiceSavedAction.print),
                      icon: const Icon(Icons.print_rounded),
                      label: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('طباعة'),
                          if (!phone) _keyHint('P', cs.onPrimary),
                        ],
                      ),
                    ),
                    const SizedBox(height: AppSpace.sm),
                    Row(
                      children: [
                        action(
                          InvoiceSavedAction.share,
                          Icons.share_rounded,
                          'مشاركة',
                        ),
                        const SizedBox(width: AppSpace.sm),
                        action(
                          InvoiceSavedAction.newInvoice,
                          Icons.add_rounded,
                          'فاتورة جديدة',
                          key: 'N',
                        ),
                      ],
                    ),
                    TextButton(
                      key: const Key('invoice-saved-done'),
                      onPressed: () => _close(InvoiceSavedAction.done),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('تم'),
                          if (!phone) _keyHint('Enter', cs.primary),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyP): () =>
            _close(InvoiceSavedAction.print),
        const SingleActivator(LogicalKeyboardKey.keyN): () =>
            _close(InvoiceSavedAction.newInvoice),
        const SingleActivator(LogicalKeyboardKey.enter): () =>
            _close(InvoiceSavedAction.done),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
            _close(InvoiceSavedAction.done),
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            _close(InvoiceSavedAction.done),
      },
      child: Focus(
        autofocus: true,
        child: SafeArea(
          bottom: !phone,
          child: Align(
            alignment: phone ? Alignment.bottomCenter : Alignment.center,
            child: Padding(
              padding: phone
                  ? EdgeInsets.zero
                  : const EdgeInsets.all(AppSpace.lg),
              child: card,
            ),
          ),
        ),
      ),
    );
  }
}
