import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../utils/bidi.dart';
import 'voucher_details_screen.dart';

/// A voucher just saved (the owner, 20 Oct 2026: «a page that says it was
/// saved, with its number, to print it or write the next»). The screen used to
/// close on a message that went with it; the employee was left at home with
/// no number and nothing to do next.
///
/// It says the number the server gave, whether the voucher is approved or
/// waits for an approver, and what it was -- the party and each line as the
/// review said them. Its next steps: open it (to print), write another of the
/// same kind, or go back to where the voucher was opened from.
class VoucherSavedScreen extends StatelessWidget {
  const VoucherSavedScreen({
    super.key,
    required this.voucherType,
    required this.voucherId,
    required this.voucherNumber,
    required this.status,
    required this.partyName,
    required this.lines,
    required this.newVoucher,
    this.edited = false,
  });

  /// 'receipt' or 'payment'.
  final String voucherType;
  final int? voucherId;
  final String? voucherNumber;

  /// As the server answered: 'approved', or waiting ('pending').
  final String? status;
  final String partyName;

  /// Each line as the review said it: where, and how much.
  final List<(String, String)> lines;

  /// Another voucher of the same kind, empty.
  final WidgetBuilder newVoucher;
  final bool edited;

  bool get _isReceipt => voucherType == 'receipt';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tones = AppSemanticColors.of(context);
    final approved = status == 'approved';
    final tone = approved ? tones.ready : tones.warning;
    final kind = _isReceipt ? 'سند القبض' : 'سند الصرف';

    return Scaffold(
      appBar: AppBar(
        title: Text(_isReceipt ? 'سند قبض' : 'سند صرف'),
        automaticallyImplyLeading: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: ListView(
            padding: const EdgeInsets.all(AppSpace.lg),
            children: [
              Icon(Icons.check_circle, size: 64, color: tones.ready.fg),
              const SizedBox(height: AppSpace.md),
              Text(
                edited ? 'عُدِّل $kind' : 'حُفظ $kind',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: AppSpace.xs),
              Text(
                ltrIsolate(voucherNumber ?? '#${voucherId ?? ''}'),
                key: const Key('voucher-saved-number'),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: AppSpace.sm),
              Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpace.md,
                    vertical: AppSpace.xs,
                  ),
                  decoration: BoxDecoration(
                    color: tone.container,
                    borderRadius: BorderRadius.circular(AppRadius.chip),
                  ),
                  child: Text(
                    approved ? 'مُعتمد' : 'بانتظار الاعتماد',
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: tone.onContainer,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.xl),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpace.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _row(theme, _isReceipt ? 'من' : 'إلى', partyName),
                      const Divider(),
                      for (final (where, what) in lines) _row(theme, where, what),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AppSpace.xl),
              if (voucherId != null)
                FilledButton.icon(
                  key: const Key('voucher-saved-open'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => VoucherDetailsScreen(voucherId: voucherId!),
                    ),
                  ),
                  icon: const Icon(Icons.receipt_long),
                  label: const Text('عرض السند وطباعته'),
                ),
              const SizedBox(height: AppSpace.sm),
              OutlinedButton.icon(
                key: const Key('voucher-saved-new'),
                onPressed: () => Navigator.of(context).pushReplacement(
                  MaterialPageRoute(builder: newVoucher),
                ),
                icon: const Icon(Icons.add),
                label: Text(_isReceipt ? 'سند قبض جديد' : 'سند صرف جديد'),
              ),
              const SizedBox(height: AppSpace.sm),
              TextButton(
                key: const Key('voucher-saved-back'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('رجوع'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(ThemeData theme, String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: AppSpace.xs),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 140, child: Text(label, style: theme.textTheme.bodyMedium)),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    ),
  );
}
