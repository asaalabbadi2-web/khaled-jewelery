import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_theme.dart';
import '../utils/currency_utils.dart';

/// ADR-060 ف١: the review before an invoice is saved, read as a receipt --
/// who and where, the lines in a table, then what it comes to and how it is
/// paid, and what remains, once. The owner, 24-25 Oct 2026: «ما الذي ينقصها
/// لتصبح مفيدة ومرتّبة أكثر» and, of many lines, «ماذا كانت الأصناف كثيرة».
///
/// The four invoices (sale, scrap sale, scrap purchase, purchase) fill it with
/// their own facts; it computes none but the weight of each karat it lists.
///
/// - A long invoice scrolls its lines alone: the totals and the buttons stay
///   in view.
/// - A notice on a line names it, the line is marked, and «اذهب إليه» brings
///   the table to it.
/// - Enter saves, Esc goes back to the invoice.

/// One line of the invoice, as the screen has it.
class InvoiceReviewLine {
  const InvoiceReviewLine({
    required this.name,
    required this.weight,
    required this.amount,
    this.karat,
  });

  final String name;
  final int? karat;
  final double weight;
  final double amount;
}

/// What the user should see before saving. [line] (0-based) is the line it is
/// about, when it is about one.
class InvoiceReviewNotice {
  const InvoiceReviewNotice(this.text, {this.line});

  final String text;
  final int? line;
}

/// An amount with its label: a payment, a tax.
class InvoiceReviewAmount {
  const InvoiceReviewAmount(this.label, this.amount);

  final String label;
  final double amount;
}

/// What the save does to a balance: as it is now, and after.
class InvoiceReviewEffect {
  const InvoiceReviewEffect({
    required this.label,
    required this.now,
    required this.after,
  });

  final String label;
  final String now;
  final String after;
}

class InvoiceReview {
  const InvoiceReview({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.tone,
    required this.lines,
    required this.total,
    required this.currency,
    this.amountLabel = 'المبلغ',
    this.notices = const [],
    this.tax,
    this.payments = const [],
    this.due,
    this.facts = const [],
    this.effectsTitle,
    this.effectsSaid = const [],
    this.effects = const [],
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final SemanticTone tone;
  final List<InvoiceReviewLine> lines;

  /// The last column's name: «المبلغ», or «الأجرة» on a supplier's purchase,
  /// whose gold is paid in gold.
  final String amountLabel;
  final List<InvoiceReviewNotice> notices;
  final double? tax;
  final double total;
  final List<InvoiceReviewAmount> payments;

  /// What remains to be paid, said once («آجل على «العميل»»).
  final InvoiceReviewAmount? due;

  /// The invoice's other facts, a line each («الصور المرفقة: 3»).
  final List<(String, String)> facts;
  final String? effectsTitle;

  /// What the save does, in words («سيزيد ما علينا للمورد نقدًا بـ …»).
  final List<String> effectsSaid;

  /// The balances it touches, now and after.
  final List<InvoiceReviewEffect> effects;
  final String currency;
}

/// Shows [review]; true when the user saves, false when they go back.
Future<bool> showInvoiceReview(BuildContext context, InvoiceReview review) async {
  // The screen's direction, not the app's: a route above it does not inherit
  // it, and an Arabic invoice under an English app read mirrored.
  final direction = Directionality.of(context);
  final saved = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: false,
    barrierLabel: review.title,
    barrierColor: Theme.of(context).colorScheme.scrim.withValues(alpha: 0.45),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (_, _, _) => Directionality(
      textDirection: direction,
      child: _InvoiceReviewDialog(review: review),
    ),
    transitionBuilder: (_, animation, _, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
      child: child,
    ),
  );
  return saved ?? false;
}

class _InvoiceReviewDialog extends StatefulWidget {
  const _InvoiceReviewDialog({required this.review});

  final InvoiceReview review;

  @override
  State<_InvoiceReviewDialog> createState() => _InvoiceReviewDialogState();
}

class _InvoiceReviewDialogState extends State<_InvoiceReviewDialog> {
  static const _rowHeight = 40.0;
  final _lines = ScrollController();

  @override
  void dispose() {
    _lines.dispose();
    super.dispose();
  }

  InvoiceReview get r => widget.review;

  bool get _phone => MediaQuery.sizeOf(context).width < 700;

  /// How many lines show before the table scrolls.
  int get _visibleRows => _phone ? 6 : 8;

  bool get _scrolls => r.lines.length > _visibleRows;

  void _goToLine(int line) {
    if (!_lines.hasClients) return;
    final target = ((line - 2) * _rowHeight).clamp(
      0.0,
      _lines.position.maxScrollExtent,
    );
    _lines.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Set<int> get _flagged => {
    for (final n in r.notices)
      if (n.line != null) n.line!,
  };

  String _money(double v) => formatAmount(v);

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
        _figure(_money(v), style: base),
        const SizedBox(width: AppSpace.xs),
        Text(r.currency, style: base?.copyWith(fontWeight: FontWeight.w400)),
      ],
    );
  }

  Widget _karat(int k) {
    final tone = AppSemanticColors.of(context).karat(k);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.sm, vertical: 2),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.chip),
      ),
      child: Text(
        '$k',
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: tone.onContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _row({
    Key? key,
    required Widget number,
    required Widget name,
    required Widget karat,
    required Widget weight,
    required Widget amount,
    Color? color,
  }) {
    return Container(
      key: key,
      height: _rowHeight,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: AppSpace.md),
      child: Row(
        children: [
          SizedBox(width: 28, child: number),
          const SizedBox(width: AppSpace.sm),
          Expanded(child: name),
          SizedBox(width: _phone ? 40 : 60, child: Center(child: karat)),
          SizedBox(
            width: _phone ? 66 : 96,
            child: Align(alignment: AlignmentDirectional.centerEnd, child: weight),
          ),
          SizedBox(
            width: _phone ? 88 : 120,
            child: Align(alignment: AlignmentDirectional.centerEnd, child: amount),
          ),
        ],
      ),
    );
  }

  Widget _table() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = theme.textTheme;
    final tones = AppSemanticColors.of(context);
    final head = t.labelMedium?.copyWith(color: cs.onSurfaceVariant);
    final flagged = _flagged;
    Widget line(int i) {
      final l = r.lines[i];
      final bad = flagged.contains(i);
      final ink = bad ? tones.warning.onContainer : null;
      return _row(
        key: Key('invoice-review-line-$i'),
        color: bad ? tones.warning.container : null,
        number: _figure('${i + 1}', style: t.bodySmall?.copyWith(color: ink)),
        name: Row(
          children: [
            if (bad) ...[
              Icon(Icons.warning_amber_rounded, size: 16, color: ink),
              const SizedBox(width: AppSpace.xs),
            ],
            Flexible(
              child: Text(
                l.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: t.bodyLarge?.copyWith(
                  color: ink,
                  fontWeight: bad ? FontWeight.w700 : null,
                ),
              ),
            ),
          ],
        ),
        karat: l.karat == null ? const SizedBox.shrink() : _karat(l.karat!),
        weight: _figure(formatGrams(l.weight)),
        amount: _figure(_money(l.amount)),
      );
    }

    return Container(
      key: const Key('invoice-review-lines'),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(AppRadius.control),
        border: Border.all(color: cs.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _row(
            number: Text('#', style: head),
            name: Text('الصنف', style: head),
            karat: Text('العيار', style: head),
            weight: Text('الوزن (جم)', style: head),
            amount: Text(r.amountLabel, style: head),
          ),
          Divider(height: 1, color: cs.outlineVariant),
          if (_scrolls)
            // Only the lines scroll; what they come to stays in view.
            SizedBox(
              height: _visibleRows * _rowHeight,
              child: Scrollbar(
                controller: _lines,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _lines,
                  padding: EdgeInsets.zero,
                  itemExtent: _rowHeight,
                  itemCount: r.lines.length,
                  itemBuilder: (_, i) => line(i),
                ),
              ),
            )
          else
            for (var i = 0; i < r.lines.length; i++) line(i),
        ],
      ),
    );
  }

  Widget _notice(InvoiceReviewNotice n) {
    final tone = AppSemanticColors.of(context).warning;
    final t = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpace.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpace.md,
        vertical: AppSpace.sm,
      ),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 20, color: tone.onContainer),
          const SizedBox(width: AppSpace.sm),
          Expanded(
            child: Text(
              n.text,
              style: t.bodyMedium?.copyWith(
                color: tone.onContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (n.line != null && _scrolls)
            TextButton(
              key: Key('invoice-review-go-${n.line}'),
              onPressed: () => _goToLine(n.line!),
              style: TextButton.styleFrom(foregroundColor: tone.onContainer),
              child: const Text('اذهب إليه'),
            ),
        ],
      ),
    );
  }

  Widget _kv(
    String label,
    Widget value, {
    bool strong = false,
    bool indent = false,
  }) {
    final t = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsetsDirectional.only(
        start: indent ? AppSpace.lg : 0,
        top: 2,
        bottom: 2,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: (strong ? t.titleLarge : t.bodyLarge)?.copyWith(
                color: indent ? cs.onSurfaceVariant : null,
                fontWeight: strong ? FontWeight.w700 : null,
              ),
            ),
          ),
          value,
        ],
      ),
    );
  }

  Widget _weights() {
    final byKarat = <int, double>{};
    for (final l in r.lines) {
      if (l.karat == null) continue;
      byKarat[l.karat!] = (byKarat[l.karat!] ?? 0) + l.weight;
    }
    if (byKarat.isEmpty) return const SizedBox.shrink();
    final karats = byKarat.keys.toList()..sort((a, b) => b - a);
    final t = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
      child: Row(
        children: [
          Text('الوزن', style: t.bodyLarge),
          const Spacer(),
          for (final k in karats) ...[
            const SizedBox(width: AppSpace.md),
            _karat(k),
            const SizedBox(width: AppSpace.xs),
            _figure(formatGrams(byKarat[k]!)),
            Text(' جم', style: t.bodyMedium),
          ],
        ],
      ),
    );
  }

  Widget _effects() {
    final tone = AppSemanticColors.of(context).info;
    final t = Theme.of(context).textTheme;
    return Container(
      key: const Key('invoice-review-effects'),
      margin: const EdgeInsets.only(top: AppSpace.md),
      padding: const EdgeInsets.all(AppSpace.md),
      decoration: BoxDecoration(
        color: tone.container,
        borderRadius: BorderRadius.circular(AppRadius.control),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            r.effectsTitle ?? '',
            style: t.titleMedium?.copyWith(
              color: tone.onContainer,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: AppSpace.xs),
          for (final said in r.effectsSaid)
            Text(
              said,
              style: t.bodyLarge?.copyWith(color: tone.onContainer),
            ),
          if (r.effectsSaid.isNotEmpty && r.effects.isNotEmpty)
            const SizedBox(height: AppSpace.xs),
          for (final e in r.effects)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      e.label,
                      style: t.bodyLarge?.copyWith(color: tone.onContainer),
                    ),
                  ),
                  Text(
                    e.now,
                    style: t.bodyMedium?.copyWith(color: tone.onContainer),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpace.sm,
                    ),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 16,
                      color: tone.onContainer,
                    ),
                  ),
                  Text(
                    e.after,
                    style: t.titleMedium?.copyWith(
                      color: tone.onContainer,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
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

  void _close(bool save) => Navigator.of(context).pop(save);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final t = theme.textTheme;
    final tones = AppSemanticColors.of(context);
    final phone = _phone;
    final size = MediaQuery.sizeOf(context);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpace.lg,
        AppSpace.md,
        AppSpace.lg,
        AppSpace.sm,
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: r.tone.container,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Icon(r.icon, color: r.tone.onContainer),
          ),
          const SizedBox(width: AppSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.title, style: t.headlineSmall),
                if (r.subtitle.isNotEmpty)
                  Text(
                    r.subtitle,
                    style: t.bodyMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'رجوع للتعديل',
            onPressed: () => _close(false),
            icon: Icon(Icons.close_rounded, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final n in r.notices) _notice(n),
        Row(
          children: [
            Text(
              'الأصناف',
              style: t.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: AppSpace.sm),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: 1,
              ),
              decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.pill),
              ),
              child: Text(
                '${r.lines.length}',
                key: const Key('invoice-review-count'),
                style: t.labelMedium?.copyWith(color: cs.onSecondaryContainer),
              ),
            ),
            const Spacer(),
            if (_scrolls) Text('مرّر لرؤية الكل', style: t.bodySmall),
          ],
        ),
        const SizedBox(height: AppSpace.xs),
        _table(),
        _weights(),
        Divider(height: 1, color: cs.outlineVariant),
        const SizedBox(height: AppSpace.xs),
        for (final (label, value) in r.facts)
          _kv(label, Text(value, style: t.bodyLarge)),
        if (r.tax != null) _kv('الضريبة', _amount(r.tax!)),
        _kv(
          'الإجمالي',
          _amount(r.total, style: t.headlineSmall),
          strong: true,
        ),
        for (final p in r.payments) _kv(p.label, _amount(p.amount), indent: true),
        if (r.due != null)
          Container(
            key: const Key('invoice-review-due'),
            margin: const EdgeInsets.only(top: AppSpace.xs),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpace.md,
              vertical: AppSpace.xs,
            ),
            decoration: BoxDecoration(
              color: tones.blocked.container,
              borderRadius: BorderRadius.circular(AppRadius.control),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    r.due!.label,
                    style: t.bodyLarge?.copyWith(
                      color: tones.blocked.onContainer,
                    ),
                  ),
                ),
                _amount(
                  r.due!.amount,
                  style: t.titleLarge?.copyWith(
                    color: tones.blocked.onContainer,
                  ),
                ),
              ],
            ),
          ),
        if (r.effects.isNotEmpty || r.effectsSaid.isNotEmpty) _effects(),
        const SizedBox(height: AppSpace.md),
      ],
    );

    final footer = DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: cs.outlineVariant)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpace.md),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton(
                key: const Key('invoice-review-back'),
                onPressed: () => _close(false),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Flexible(child: Text('رجوع للتعديل')),
                    if (!phone) _keyHint('Esc', cs.onSurfaceVariant),
                  ],
                ),
              ),
            ),
            const SizedBox(width: AppSpace.md),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                key: const Key('invoice-review-save'),
                onPressed: () => _close(true),
                icon: const Icon(Icons.save_rounded),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('حفظ الفاتورة'),
                    if (!phone) _keyHint('Enter', cs.onPrimary),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final card = Material(
      key: const Key('invoice-review'),
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
          maxWidth: phone ? size.width : 640,
          maxHeight: size.height * (phone ? 0.94 : 0.92),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            // On a short screen the rest scrolls too; the buttons never do.
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg),
                child: body,
              ),
            ),
            footer,
          ],
        ),
      ),
    );

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter): () => _close(true),
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () =>
            _close(true),
        const SingleActivator(LogicalKeyboardKey.escape): () => _close(false),
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
