import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../../../../theme/app_theme.dart';

class HeroProfitSection extends StatelessWidget {
  final Map<String, dynamic> kpis;
  final Map<String, dynamic> liquidity;
  final Map<String, dynamic> salesPurchasesSummary;
  final bool isArabic;
  final double Function(double) scale;
  final NumberFormat currencyFormat;
  /// 'today' | 'month' | 'year'
  final String summaryPeriod;

  const HeroProfitSection({
    super.key,
    required this.kpis,
    required this.liquidity,
    required this.salesPurchasesSummary,
    required this.isArabic,
    required this.scale,
    required this.currencyFormat,
    required this.summaryPeriod,
  });

  double _asDouble(dynamic v) => v is num ? v.toDouble() : 0.0;
  double? _asDoubleOrNull(dynamic v) => v is num ? v.toDouble() : null;
  String _fmtC(double v) => currencyFormat.format(v);
  double _s(double v) => scale(v);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final periodData = (salesPurchasesSummary[summaryPeriod] as Map<String, dynamic>?) ?? {};
    final salesData = (periodData['sales'] as Map<String, dynamic>?) ?? {};
    final purchasesData = (periodData['purchases'] as Map<String, dynamic>?) ?? {};
    final expensesData = (periodData['expenses'] as Map<String, dynamic>?) ?? {};

    final periodSales = _asDouble(salesData['total_value']);
    final periodPurchases = _asDouble(purchasesData['total_value']);
    final periodExpenses = _asDouble(expensesData['total_value']);
    final periodProfit = periodSales - periodPurchases - periodExpenses;
    final periodMargin = periodSales > 0 ? (periodProfit / periodSales) * 100 : null;
    final cashAvailable = _asDouble(liquidity['cash_available']);

    final vsYesterdayPct = summaryPeriod == 'today'
        ? _asDoubleOrNull(kpis['today_profit_vs_yesterday_pct'])
        : null;

    final isProfit = periodProfit >= 0;
    final profitColor = isProfit ? AppColors.success : Colors.red.shade600;

    final String periodTitle;
    switch (summaryPeriod) {
      case 'month':
        periodTitle = isArabic ? 'صافي ربح الشهر' : 'Monthly Net Profit';
        break;
      case 'year':
        periodTitle = isArabic ? 'صافي ربح السنة' : 'Yearly Net Profit';
        break;
      default:
        periodTitle = isArabic ? 'صافي ربح اليوم' : "Today's Net Profit";
    }

    // Compact card — no outer Padding (caller handles spacing)
    return Container(
      padding: EdgeInsets.all(_s(14)),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: isProfit
              ? [AppColors.success.withValues(alpha: 0.06), theme.cardColor]
              : [Colors.red.shade600.withValues(alpha: 0.06), theme.cardColor],
        ),
        borderRadius: BorderRadius.circular(_s(14)),
        border: Border.all(color: profitColor.withValues(alpha: 0.20)),
        boxShadow: [
          BoxShadow(
            color: profitColor.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Row(
            children: [
              Container(
                width: _s(32),
                height: _s(32),
                decoration: BoxDecoration(
                  color: profitColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  isProfit ? Icons.trending_up_rounded : Icons.trending_down_rounded,
                  color: profitColor,
                  size: _s(16),
                ),
              ),
              SizedBox(width: _s(8)),
              Expanded(
                child: Text(
                  periodTitle,
                  style: TextStyle(
                    fontSize: _s(13),
                    fontWeight: FontWeight.w700,
                    color: profitColor,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (vsYesterdayPct != null)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: _s(6), vertical: _s(2)),
                  decoration: BoxDecoration(
                    color: (vsYesterdayPct >= 0 ? Colors.green : Colors.red)
                        .withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        vsYesterdayPct >= 0
                            ? Icons.arrow_upward
                            : Icons.arrow_downward,
                        size: _s(10),
                        color: vsYesterdayPct >= 0
                            ? Colors.green.shade700
                            : Colors.red.shade600,
                      ),
                      Text(
                        '${vsYesterdayPct.abs().toStringAsFixed(1)}%',
                        style: TextStyle(
                          fontSize: _s(9),
                          fontWeight: FontWeight.bold,
                          color: vsYesterdayPct >= 0
                              ? Colors.green.shade700
                              : Colors.red.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          SizedBox(height: _s(10)),

          // Hero number + margin + status badges
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Flexible(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: AlignmentDirectional.centerStart,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        _fmtC(periodProfit).replaceAll(currencyFormat.currencySymbol, '').trim(),
                        style: TextStyle(
                          fontWeight: FontWeight.w900,
                          color: profitColor,
                          fontSize: _s(22),
                          letterSpacing: -0.5,
                        ),
                      ),
                      SizedBox(width: _s(4)),
                      Padding(
                        padding: EdgeInsets.only(bottom: _s(3)),
                        child: Text(
                          currencyFormat.currencySymbol,
                          style: TextStyle(
                            color: profitColor.withValues(alpha: 0.7),
                            fontWeight: FontWeight.w600,
                            fontSize: _s(11),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              if (periodMargin != null)
                Container(
                  padding: EdgeInsets.symmetric(
                      horizontal: _s(7), vertical: _s(3)),
                  decoration: BoxDecoration(
                    color: profitColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${periodMargin.toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: _s(10),
                      fontWeight: FontWeight.bold,
                      color: profitColor,
                    ),
                  ),
                ),
              SizedBox(width: _s(4)),
              Container(
                padding: EdgeInsets.symmetric(
                    horizontal: _s(7), vertical: _s(3)),
                decoration: BoxDecoration(
                  color: profitColor.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isProfit ? Icons.check_circle : Icons.cancel,
                      size: _s(10),
                      color: profitColor,
                    ),
                    SizedBox(width: _s(2)),
                    Text(
                      isProfit
                          ? (isArabic ? 'ربح' : 'Profit')
                          : (isArabic ? 'خسارة' : 'Loss'),
                      style: TextStyle(
                        fontSize: _s(10),
                        fontWeight: FontWeight.bold,
                        color: profitColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          SizedBox(height: _s(10)),

          // 3 chips
          Row(
            children: [
              Expanded(
                child: _chip(context, Icons.account_balance_wallet_outlined,
                    isArabic ? 'السيولة' : 'Cash',
                    _fmtC(cashAvailable)
                        .replaceAll(currencyFormat.currencySymbol, '')
                        .trim(),
                    Theme.of(context).colorScheme.primary),
              ),
              SizedBox(width: _s(6)),
              Expanded(
                child: _chip(context, Icons.arrow_upward,
                    isArabic ? 'مبيعات' : 'Sales',
                    _fmtC(periodSales)
                        .replaceAll(currencyFormat.currencySymbol, '')
                        .trim(),
                    const Color(0xFF1B9E4B)),
              ),
              SizedBox(width: _s(6)),
              Expanded(
                child: _chip(context, Icons.arrow_downward,
                    isArabic ? 'مشتريات' : 'Purch.',
                    _fmtC(periodPurchases)
                        .replaceAll(currencyFormat.currencySymbol, '')
                        .trim(),
                    Colors.orange.shade700),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, IconData icon, String label, String value, Color color) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.symmetric(horizontal: _s(7), vertical: _s(5)),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Row(
        children: [
          Icon(icon, size: _s(11), color: color),
          SizedBox(width: _s(4)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(label,
                    style: TextStyle(fontSize: _s(9), color: theme.hintColor),
                    overflow: TextOverflow.ellipsis),
                Text(value,
                    style: TextStyle(
                        fontSize: _s(10),
                        fontWeight: FontWeight.bold,
                        color: color,
                        letterSpacing: -0.2),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
