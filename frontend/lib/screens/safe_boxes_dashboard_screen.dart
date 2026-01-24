import 'dart:async';
import 'package:flutter/material.dart';
import '../api_service.dart';
import '../models/safe_box_model.dart';
import '../theme/app_theme.dart';
import 'gold_safe_transfer_screen.dart';
import 'safe_boxes_screen.dart';

/// لوحة تحكم متقدمة لمراقبة خزائن الذهب
class SafeBoxesDashboardScreen extends StatefulWidget {
  const SafeBoxesDashboardScreen({super.key});

  @override
  State<SafeBoxesDashboardScreen> createState() => _SafeBoxesDashboardScreenState();
}

class _SafeBoxesDashboardScreenState extends State<SafeBoxesDashboardScreen> {
  final ApiService _api = ApiService();
  List<SafeBoxModel> _safes = [];
  bool _isLoading = false;
  Timer? _refreshTimer;
  DateTime? _lastUpdate;

  @override
  void initState() {
    super.initState();
    _loadDashboardData();
    // تحديث تلقائي كل 30 ثانية
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _loadDashboardData(silent: true);
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadDashboardData({bool silent = false}) async {
    if (!silent) setState(() => _isLoading = true);
    
    try {
      // تحميل خزائن الذهب فقط
      final safes = await _api.getSafeBoxes(
        safeType: 'gold',
        includeBalance: true,
        includeAccount: true,
      );
      
      setState(() {
        _safes = safes;
        _lastUpdate = DateTime.now();
        if (!silent) _isLoading = false;
      });
    } catch (e) {
      if (!silent) {
        setState(() => _isLoading = false);
        _showSnack('خطأ في تحميل البيانات: $e', isError: true);
      }
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: const Text('لوحة مراقبة الخزائن'),
        backgroundColor: AppColors.primaryGold,
        foregroundColor: Colors.white,
        actions: [
          // زر التحديث اليدوي
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _isLoading ? null : () => _loadDashboardData(),
            tooltip: 'تحديث',
          ),
          // زر تحويل الذهب
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => GoldSafeTransferScreen(
                    api: _api,
                  ),
                ),
              ).then((_) => _loadDashboardData());
            },
            tooltip: 'تحويل ذهب',
          ),
          // زر إدارة الخزائن
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => SafeBoxesScreen(
                    initialFilterType: 'gold',
                    lockFilterType: true,
                    balancesView: true,
                  ),
                ),
              ).then((_) => _loadDashboardData());
            },
            tooltip: 'إدارة الخزائن',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadDashboardData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // معلومات آخر تحديث
                    _buildLastUpdateBanner(isDark),
                    const SizedBox(height: 16),
                    
                    // إحصائيات سريعة
                    _buildQuickStats(isDark),
                    const SizedBox(height: 24),
                    
                    // بطاقات الخزائن
                    if (_safes.isEmpty)
                      _buildEmptyState()
                    else
                      ..._safes.map((safe) => Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: _buildSafeCard(safe, theme, isDark),
                      )),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildLastUpdateBanner(bool isDark) {
    if (_lastUpdate == null) return const SizedBox.shrink();
    
    final elapsed = DateTime.now().difference(_lastUpdate!);
    final timeText = elapsed.inSeconds < 60
        ? 'منذ ${elapsed.inSeconds} ثانية'
        : elapsed.inMinutes < 60
        ? 'منذ ${elapsed.inMinutes} دقيقة'
        : 'منذ ${elapsed.inHours} ساعة';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.grey[100],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primaryGold.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.access_time,
            size: 18,
            color: AppColors.primaryGold,
          ),
          const SizedBox(width: 8),
          Text(
            'آخر تحديث: $timeText',
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.grey[400] : Colors.grey[700],
            ),
          ),
          const Spacer(),
          Icon(
            Icons.circle,
            size: 10,
            color: Colors.green,
          ),
          const SizedBox(width: 4),
          Text(
            'متصل',
            style: TextStyle(
              fontSize: 12,
              color: Colors.green,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickStats(bool isDark) {
    final totalSafes = _safes.length;
    final activeSafes = _safes.where((s) => s.isActive).length;
    
    // حساب إجمالي الأوزان
    double total18k = 0, total21k = 0, total22k = 0, total24k = 0;
    for (final safe in _safes.where((s) => s.safeType == 'gold')) {
      total18k += safe.weightBalance?['18'] ?? 0;
      total21k += safe.weightBalance?['21'] ?? 0;
      total22k += safe.weightBalance?['22'] ?? 0;
      total24k += safe.weightBalance?['24'] ?? 0;
    }
    
    final totalWeight = total18k + total21k + total22k + total24k;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'الإحصائيات السريعة',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : Colors.grey[900],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                icon: Icons.account_balance_wallet,
                label: 'إجمالي الخزائن',
                value: '$totalSafes',
                color: AppColors.info,
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildStatCard(
                icon: Icons.check_circle,
                label: 'الخزائن النشطة',
                value: '$activeSafes',
                color: AppColors.success,
                isDark: isDark,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildTotalWeightCard(
          total18k: total18k,
          total21k: total21k,
          total22k: total22k,
          total24k: total24k,
          totalWeight: totalWeight,
          isDark: isDark,
        ),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 32),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: isDark ? Colors.grey[400] : Colors.grey[600],
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildTotalWeightCard({
    required double total18k,
    required double total21k,
    required double total22k,
    required double total24k,
    required double totalWeight,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppColors.primaryGold.withValues(alpha: isDark ? 0.3 : 0.15),
            AppColors.lightGold.withValues(alpha: isDark ? 0.2 : 0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: AppColors.primaryGold.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.scale,
                color: AppColors.primaryGold,
                size: 24,
              ),
              const SizedBox(width: 8),
              Text(
                'إجمالي الأوزان في جميع الخزائن',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.grey[900],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _buildKaratChip('18k', total18k, AppColors.karat18),
              _buildKaratChip('21k', total21k, AppColors.karat21),
              _buildKaratChip('22k', total22k, AppColors.karat22),
              _buildKaratChip('24k', total24k, AppColors.karat24),
            ],
          ),
          const Divider(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'الإجمالي الكلي:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.grey[900],
                ),
              ),
              Text(
                '${totalWeight.toStringAsFixed(3)} جم',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: AppColors.primaryGold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildKaratChip(String label, double weight, Color color) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withValues(alpha: 0.3)),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          weight.toStringAsFixed(2),
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ],
    );
  }

  Widget _buildSafeCard(SafeBoxModel safe, ThemeData theme, bool isDark) {
final hasLowBalance = (safe.weightBalance?['18'] ?? 0) < 10 &&
                          (safe.weightBalance?['21'] ?? 0) < 10 &&
                          (safe.weightBalance?['22'] ?? 0) < 10 &&
                          (safe.weightBalance?['24'] ?? 0) < 10;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? Colors.grey[850] : Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: safe.isActive
              ? AppColors.primaryGold.withValues(alpha: 0.3)
              : Colors.grey.withValues(alpha: 0.3),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.3 : 0.08),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: safe.isActive
                    ? [
                        AppColors.primaryGold.withValues(alpha: isDark ? 0.3 : 0.2),
                        AppColors.lightGold.withValues(alpha: isDark ? 0.2 : 0.1),
                      ]
                    : [
                        Colors.grey.withValues(alpha: 0.2),
                        Colors.grey.withValues(alpha: 0.1),
                      ],
              ),
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(14),
                topRight: Radius.circular(14),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: safe.isActive
                        ? AppColors.primaryGold.withValues(alpha: 0.2)
                        : Colors.grey.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.account_balance_wallet,
                    color: safe.isActive ? AppColors.primaryGold : Colors.grey,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        safe.name,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: isDark ? Colors.white : Colors.grey[900],
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            safe.isActive ? Icons.check_circle : Icons.cancel,
                            size: 16,
                            color: safe.isActive ? Colors.green : Colors.grey,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            safe.isActive ? 'نشط' : 'غير نشط',
                            style: TextStyle(
                              fontSize: 13,
                              color: safe.isActive ? Colors.green : Colors.grey,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (hasLowBalance && safe.isActive) ...[
                            const SizedBox(width: 12),
                            Icon(
                              Icons.warning,
                              size: 16,
                              color: Colors.orange,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'رصيد منخفض',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.orange,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          
          // الأرصدة
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'الأرصدة الحالية',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                  ),
                ),
                const SizedBox(height: 12),
                _buildBalanceRow('18k', safe.weightBalance?['18'] ?? 0, AppColors.karat18, isDark),
                const SizedBox(height: 8),
                _buildBalanceRow('21k', safe.weightBalance?['21'] ?? 0, AppColors.karat21, isDark),
                const SizedBox(height: 8),
                _buildBalanceRow('22k', safe.weightBalance?['22'] ?? 0, AppColors.karat22, isDark),
                const SizedBox(height: 8),
                _buildBalanceRow('24k', safe.weightBalance?['24'] ?? 0, AppColors.karat24, isDark),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBalanceRow(String karat, double balance, Color color, bool isDark) {
    final isLow = balance < 10;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isLow ? Colors.orange.withValues(alpha: 0.5) : color.withValues(alpha: 0.2),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  karat,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              if (isLow) ...[
                const SizedBox(width: 8),
                Icon(
                  Icons.warning_amber,
                  size: 18,
                  color: Colors.orange,
                ),
              ],
            ],
          ),
          Text(
            '${balance.toStringAsFixed(3)} جم',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.account_balance_wallet_outlined,
              size: 80,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 16),
            Text(
              'لا توجد خزائن ذهب',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'قم بإضافة خزينة ذهب من إعدادات الخزائن',
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey[500],
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
