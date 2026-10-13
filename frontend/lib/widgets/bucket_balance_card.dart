import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/inventory_models.dart';
import '../services/inventory_service.dart';
import '../theme/app_theme.dart';

/// Reusable card showing the stock of one (location, category, karat) --
/// the books themselves (ADR-045).
///
/// Usage — standalone:
///   BucketBalanceCard(safeBoxId: 30, categoryId: 3, karat: 21)
///
/// Usage — from pre-loaded data:
///   BucketBalanceCard.fromBucket(bucket)
///
/// Phase B: drop this card into the invoice screen to show live impact.
class BucketBalanceCard extends StatefulWidget {
  final int? safeBoxId;
  final int? categoryId;
  final double karat;
  final InventoryBucket? initialData; // skip first fetch if already loaded
  final bool compact;

  const BucketBalanceCard({
    super.key,
    required this.safeBoxId,
    required this.categoryId,
    required this.karat,
    this.initialData,
    this.compact = false,
  });

  factory BucketBalanceCard.fromBucket(
    InventoryBucket bucket, {
    Key? key,
    bool compact = false,
  }) =>
      BucketBalanceCard(
        key: key,
        safeBoxId: bucket.safeBoxId,
        categoryId: bucket.categoryId,
        karat: bucket.karat,
        initialData: bucket,
        compact: compact,
      );

  @override
  State<BucketBalanceCard> createState() => _BucketBalanceCardState();
}

class _BucketBalanceCardState extends State<BucketBalanceCard> {
  InventoryBucket? _bucket;
  bool _loading = false;
  String? _error;

  late final InventoryService _svc =
      InventoryService(ApiService());

  @override
  void initState() {
    super.initState();
    if (widget.initialData != null) {
      _bucket = widget.initialData;
    } else {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final buckets = await _svc.getBalance(
        safeBoxId: widget.safeBoxId,
        categoryId: widget.categoryId,
        karat: widget.karat,
      );
      // No category asked: the unclassified row, not every category's.
      final mine = buckets.where((b) => b.categoryId == widget.categoryId);
      setState(() {
        _bucket = mine.isNotEmpty ? mine.first : null;
        _loading = false;
      });
    } on InventoryApiException catch (e) {
      setState(() { _error = e.message; _loading = false; });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final karatColor = AppColors.karatColorFor(widget.karat);

    if (_loading) {
      return _shell(
        karatColor,
        child: const Center(
          child: SizedBox(
            width: 20, height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    if (_error != null) {
      return _shell(
        karatColor,
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, size: 16, color: AppColors.warning),
            const SizedBox(width: 6),
            Expanded(child: Text(_error!, style: const TextStyle(fontSize: 11))),
            IconButton(
              icon: const Icon(Icons.refresh, size: 16),
              onPressed: _load,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ],
        ),
      );
    }

    if (_bucket == null) {
      return _shell(
        karatColor,
        child: Text(
          'لا يوجد رصيد مسجّل',
          style: TextStyle(color: Colors.grey[500], fontSize: 12),
        ),
      );
    }

    return _shell(
      karatColor,
      child: widget.compact ? _compactBody(karatColor) : _fullBody(karatColor),
    );
  }

  Widget _fullBody(Color karatColor) {
    final b = _bucket!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final karatLabel =
        'عيار ${b.karat.toStringAsFixed(b.karat == b.karat.truncateToDouble() ? 0 : 1)}';
    final badgeTextColor = isDark
        ? karatColor
        : AppColors.karatBadgeTextColorFor(b.karat);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Weight — primary element
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${formatWeight(b.balance)} جم',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                  color: AppColors.goldText(context),
                ),
              ),
              Text(
                [b.categoryName ?? 'بلا تصنيف', if (b.safeBoxName != null) b.safeBoxName!]
                    .join(' · '),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
        // Karat badge — secondary
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: karatColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: karatColor.withOpacity(0.4)),
          ),
          child: Text(
            karatLabel,
            style: TextStyle(
              color: badgeTextColor,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
          ),
        ),
        const SizedBox(width: 6),
        IconButton(
          icon: Icon(Icons.refresh, size: 18, color: AppColors.goldText(context)),
          onPressed: _load,
          tooltip: 'تحديث',
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
        ),
      ],
    );
  }

  Widget _compactBody(Color karatColor) {
    final b = _bucket!;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark
        ? karatColor
        : AppColors.karatBadgeTextColorFor(b.karat);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8, height: 8,
          decoration: BoxDecoration(color: karatColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '${formatWeight(b.balance)} جم',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: textColor,
            fontSize: 13,
          ),
        ),
      ],
    );
  }

  Widget _shell(Color karatColor, {required Widget child}) {
    if (widget.compact) {
      return Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: child);
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: karatColor.withOpacity(0.25)),
        boxShadow: [
          BoxShadow(
            color: karatColor.withOpacity(0.06),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: child,
    );
  }

}

/// Formats a weight value: removes trailing zeros, keeps up to 4 decimal places.
String formatWeight(double w) {
  if (w == w.truncateToDouble()) return w.toInt().toString();
  final s = w.toStringAsFixed(4);
  return s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
}
