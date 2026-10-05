/// What a manual journal entry's gold balance means for saving it.
///
/// The server decides: under [kServerGoldSettleLimit] it quietly adjusts one
/// line to close the gap, from that up it refuses the entry
/// (backend/routes/journals.py, add_journal_entry). The screen only mirrors it,
/// so it neither promises a settlement the server won't make nor lets a doomed
/// save through.
enum GoldBalanceVerdict { balanced, serverWillSettle, mustFix }

/// Differences up to this are noise from rounding to 3 decimals.
const double kBalanceTolerance = 0.001;

/// The server settles a gold difference strictly under this many grams.
const double kServerGoldSettleLimit = 0.01;

GoldBalanceVerdict goldBalanceVerdict(double debit, double credit) {
  final gap = (debit - credit).abs();
  if (gap <= kBalanceTolerance) return GoldBalanceVerdict.balanced;
  if (gap < kServerGoldSettleLimit) return GoldBalanceVerdict.serverWillSettle;
  return GoldBalanceVerdict.mustFix;
}
