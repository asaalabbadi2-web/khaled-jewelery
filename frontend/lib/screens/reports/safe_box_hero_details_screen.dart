// frontend/lib/screens/reports/safe_box_hero_details_screen.dart
//
// شاشة تفاصيل الخزنة المنفصلة — مستخرجة من admin_dashboard_screen.dart
// تستخدم Hero animations للانتقال السلس من بطاقة الخزنة في لوحة المدير.

import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:provider/provider.dart';

import '../../api_service.dart';
import '../../models/safe_box_model.dart';
import '../../providers/settings_provider.dart';
import '../../theme/app_theme.dart';
import '../safe_boxes_screen.dart';

class SafeBoxHeroDetailsScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;
  final Map<String, dynamic> safeBox;
  final String heroTag;

  const SafeBoxHeroDetailsScreen({
    super.key,
    required this.api,
    required this.isArabic,
    required this.safeBox,
    required this.heroTag,
  });

  @override
  State<SafeBoxHeroDetailsScreen> createState() =>
      _SafeBoxHeroDetailsScreenState();
}

class _SafeBoxHeroDetailsScreenState extends State<SafeBoxHeroDetailsScreen> {
  late Map<String, dynamic> _safeBox;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _safeBox = Map<String, dynamic>.from(widget.safeBox);
    // Fetch the latest balances immediately on open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
    });
  }

  double _uiScale(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1200) return 1.20;
    if (width >= 900) return 1.12;
    if (width >= 600) return 1.04;
    return 1.0;
  }

  double _s(BuildContext context, double value) => value * _uiScale(context);

  double _asDouble(dynamic v) {
    if (v is num) return v.toDouble();
    return double.tryParse(v?.toString() ?? '') ?? 0.0;
  }

  double _sbWeight(Map<String, dynamic> sb, String key) {
    final wb = sb['weight_balance'];
    if (wb is Map) {
      final raw = wb[key];
      if (raw is num) return raw.toDouble();
      return double.tryParse(raw?.toString() ?? '') ?? 0.0;
    }
    return 0.0;
  }

  int? _safeBoxIdFromMap(Map<String, dynamic> sb) {
    final id = sb['id'];
    if (id is int) return id;
    return int.tryParse(id?.toString() ?? '');
  }

  Map<String, dynamic> _mergeFromSafeBoxModel(SafeBoxModel m) {
    return <String, dynamic>{
      'id': m.id,
      'name': m.name,
      'safe_type': m.safeType,
      'weight_balance': m.weightBalance,
      'total_weight_main_karat': m.accountTotalWeightMainKarat,
      'balance_cash': m.cashBalance,
      'balance_gold_21k': m.goldBalance21k,
      'has_recent_activity': _safeBox['has_recent_activity'] == true,
      'main_karat': m.karat,
    };
  }

  Future<void> _refresh() async {
    final id = _safeBoxIdFromMap(_safeBox);
    if (id == null) return;

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final model = await widget.api.getSafeBox(id, includeBalance: true);
      if (!mounted) return;
      setState(() {
        _safeBox = {..._safeBox, ..._mergeFromSafeBoxModel(model)};
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
      });
    } finally {
      if (!mounted) return;
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    context.watch<SettingsProvider>();

    final theme = Theme.of(context);
    final name = _safeBox['name'] ?? '-';
    final safeType = _safeBox['safe_type'] ?? 'cash';
    final cashBalance = _asDouble(_safeBox['balance_cash']);
    final hasActivity = _safeBox['has_recent_activity'] == true;

    final w18 = _sbWeight(_safeBox, '18k');
    final w21 = _sbWeight(_safeBox, '21k');
    final w22 = _sbWeight(_safeBox, '22k');
    final w24 = _sbWeight(_safeBox, '24k');

    IconData icon;
    Color color;
    String subtitle;

    switch (safeType) {
      case 'gold':
        icon = Icons.auto_awesome;
        color = AppColors.primaryGold;
        subtitle = widget.isArabic ? 'ذهب' : 'Gold';
        break;
      case 'bank':
        icon = Icons.account_balance;
        color = Colors.blue;
        subtitle = widget.isArabic ? 'بنك' : 'Bank';
        break;
      default:
        icon = Icons.account_balance_wallet;
        color = Colors.green;
        subtitle = widget.isArabic ? 'نقد' : 'Cash';
    }

    Widget buildDetailChip(String label, String value, {Color? chipColor}) {
      final c = chipColor ?? color;
      return Container(
        padding: EdgeInsets.symmetric(
          horizontal: _s(context, 10),
          vertical: _s(context, 6),
        ),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(_s(context, 12)),
          border: Border.all(color: c.withValues(alpha: 0.28)),
        ),
        child: Text(
          '$label: $value',
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
            fontSize: _s(context, 12),
          ),
        ),
      );
    }

    final heroIconTag = '${widget.heroTag}_icon';
    final heroNameTag = '${widget.heroTag}_name';

    final headerCard = Material(
      color: Colors.transparent,
      child: Container(
        padding: EdgeInsets.all(_s(context, 14)),
        decoration: BoxDecoration(
          color: theme.cardColor,
          borderRadius: BorderRadius.circular(_s(context, 16)),
          border: Border.all(
            color: (hasActivity ? Colors.green : theme.hintColor).withValues(
              alpha: 0.25,
            ),
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.10),
              blurRadius: 16,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Hero(
                  tag: heroIconTag,
                  createRectTween: (begin, end) =>
                      MaterialRectArcTween(begin: begin, end: end),
                  child: Material(
                    color: Colors.transparent,
                    child: Icon(icon, color: color, size: _s(context, 26)),
                  ),
                ),
                SizedBox(width: _s(context, 10)),
                Expanded(
                  child: Hero(
                    tag: heroNameTag,
                    createRectTween: (begin, end) =>
                        MaterialRectArcTween(begin: begin, end: end),
                    child: Material(
                      color: Colors.transparent,
                      child: Text(
                        name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                if (hasActivity)
                  Container(
                    width: _s(context, 9),
                    height: _s(context, 9),
                    decoration: const BoxDecoration(
                      color: Colors.green,
                      shape: BoxShape.circle,
                    ),
                  ),
              ],
            ),
            SizedBox(height: _s(context, 6)),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.hintColor,
              ),
            ),
          ],
        ),
      ),
    );

    final detailsContent = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_error != null)
          Padding(
            padding: EdgeInsets.only(top: _s(context, 12)),
            child: Text(
              _error!,
              style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
            ),
          ),
        SizedBox(height: _s(context, 16)),
        Card(
          elevation: 0,
          color: theme.cardColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_s(context, 16)),
            side: BorderSide(color: theme.dividerColor.withValues(alpha: 0.5)),
          ),
          child: Padding(
            padding: EdgeInsets.all(_s(context, 14)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      widget.isArabic ? 'أرصدة مباشرة' : 'Live balances',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    if (_loading)
                      SizedBox(
                        width: _s(context, 18),
                        height: _s(context, 18),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      ),
                  ],
                ),
                SizedBox(height: _s(context, 10)),
                if (safeType == 'gold')
                  Wrap(
                    spacing: _s(context, 10),
                    runSpacing: _s(context, 10),
                    children: [
                      buildDetailChip(
                        '24k',
                        _weightFmt(w24),
                        chipColor: AppColors.karat24,
                      ),
                      buildDetailChip(
                        '22k',
                        _weightFmt(w22),
                        chipColor: AppColors.karat22,
                      ),
                      buildDetailChip(
                        '21k',
                        _weightFmt(w21),
                        chipColor: AppColors.karat21,
                      ),
                      buildDetailChip(
                        '18k',
                        _weightFmt(w18),
                        chipColor: AppColors.karat18,
                      ),
                    ],
                  )
                else
                  Wrap(
                    spacing: _s(context, 10),
                    runSpacing: _s(context, 10),
                    children: [
                      buildDetailChip(
                        widget.isArabic ? 'الرصيد' : 'Balance',
                        _currencyFmt(cashBalance),
                        chipColor: color,
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.isArabic ? 'تفاصيل الخزنة' : 'Safe Box Details'),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => SafeBoxesScreen(
                    api: widget.api,
                  ),
                ),
              );
            },
            child: Text(widget.isArabic ? 'عرض الكل' : 'View all'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: ListView(
          padding: EdgeInsets.all(_s(context, 16)),
          children: [
            headerCard,
            TweenAnimationBuilder<double>(
              tween: Tween<double>(begin: 0, end: 1),
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              builder: (context, v, child) {
                return Opacity(
                  opacity: v,
                  child: Transform.translate(
                    offset: Offset(0, (1 - v) * 10),
                    child: child,
                  ),
                );
              },
              child: detailsContent,
            ),
          ],
        ),
      ),
    );
  }

  String _weightFmt(double v) {
    final f = NumberFormat('#,##0.000');
    return '${f.format(v)} g';
  }

  String _currencyFmt(double v) {
    final f = NumberFormat.currency(
      locale: widget.isArabic ? 'ar' : 'en',
      symbol: '',
      decimalDigits: 2,
    );
    final s = f.format(v).trim();
    final symbol = context.read<SettingsProvider>().currencySymbolText;
    return '$s $symbol';
  }
}
