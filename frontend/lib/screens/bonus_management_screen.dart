import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';
import 'bonus_analytics_screen.dart';
import 'bonus_rules_screen.dart';
import 'bonuses_screen.dart';
import 'calculate_bonuses_screen.dart';

class BonusManagementScreen extends StatefulWidget {
  final ApiService api;
  final bool isArabic;

  const BonusManagementScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  State<BonusManagementScreen> createState() => BonusManagementScreenState();
}

class BonusManagementScreenState extends State<BonusManagementScreen> {
  int _activeTab = 0;
  late final PageController _pageController;

  int _bonusesCount = 0;
  int _rulesCount = 0;
  int _pendingCount = 0;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _loadCounts();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _loadCounts() async {
    try {
      final bonuses = await widget.api.getBonuses();
      final rules = await widget.api.getBonusRules();
      if (!mounted) return;
      setState(() {
        _bonusesCount = bonuses.length;
        _rulesCount = rules.length;
        _pendingCount = bonuses.where((b) {
          if (b is Map) return b['status'] == 'pending';
          return false;
        }).length;
      });
    } catch (_) {}
  }

  void switchTab(int index) {
    setState(() => _activeTab = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isAr = widget.isArabic;
    final theme = Theme.of(context);

    return Directionality(
      textDirection: isAr ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        backgroundColor: theme.scaffoldBackgroundColor,
        // ── التنقل السفلي ──
        bottomNavigationBar: _buildBottomNav(theme, isAr),
        body: SafeArea(
          child: Column(
            children: [
              _buildSlimAppBar(theme, isAr),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (i) => setState(() => _activeTab = i),
                  children: [
                    BonusesScreen(
                      api: widget.api,
                      isArabic: isAr,
                      embedded: true,
                    ),
                    BonusRulesScreen(
                      api: widget.api,
                      isArabic: isAr,
                      embedded: true,
                    ),
                    CalculateBonusesScreen(
                      api: widget.api,
                      isArabic: isAr,
                      embedded: true,
                    ),
                    BonusAnalyticsScreen(
                      api: widget.api,
                      isArabic: isAr,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlimAppBar(ThemeData theme, bool isAr) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(
          bottom: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              isAr ? Icons.arrow_forward_ios : Icons.arrow_back_ios,
              size: 18,
            ),
            onPressed: () => Navigator.of(context).pop(),
            visualDensity: VisualDensity.compact,
          ),
          const SizedBox(width: 4),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              Icons.card_giftcard_rounded,
              color: Theme.of(context).colorScheme.primary,
              size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            isAr ? 'إدارة المكافآت' : 'Bonus Management',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: theme.textTheme.bodyLarge?.color,
            ),
          ),
          const Spacer(),
          if (_pendingCount > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: AppColors.warning.withValues(alpha: 0.30),
                  width: 0.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.pending_actions_rounded,
                    size: 12,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_pendingCount ${isAr ? "بانتظار الاعتماد" : "pending"}',
                    style: const TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      color: AppColors.warning,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBottomNav(ThemeData theme, bool isAr) {
    final tabs = [
      (
        icon: Icons.list_alt_rounded,
        label: isAr ? 'القائمة' : 'List',
        count: _bonusesCount > 0 ? '$_bonusesCount' : null,
      ),
      (
        icon: Icons.rule_rounded,
        label: isAr ? 'القواعد' : 'Rules',
        count: _rulesCount > 0 ? '$_rulesCount' : null,
      ),
      (
        icon: Icons.calculate_rounded,
        label: isAr ? 'احتساب' : 'Calculate',
        count: null,
      ),
      (
        icon: Icons.bar_chart_rounded,
        label: isAr ? 'التحليلات' : 'Analytics',
        count: null,
      ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: theme.cardColor,
        border: Border(
          top: BorderSide(
            color: theme.dividerColor.withValues(alpha: 0.4),
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: tabs.asMap().entries.map((e) {
              final i = e.key;
              final t = e.value;
              final isActive = _activeTab == i;
              return Expanded(
                child: InkWell(
                  onTap: () => switchTab(i),
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(
                              t.icon,
                              size: 22,
                              color: isActive
                                  ? Theme.of(context).colorScheme.primary
                                  : theme.hintColor,
                            ),
                            if (t.count != null)
                              Positioned(
                                top: -4,
                                right: -6,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? Theme.of(context).colorScheme.primary
                                        : theme.hintColor,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    t.count!,
                                    style: const TextStyle(
                                      fontSize: 8,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.label,
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            color: isActive
                                ? Theme.of(context).colorScheme.primary
                                : theme.hintColor,
                          ),
                        ),
                        const SizedBox(height: 2),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: isActive ? 20 : 0,
                          height: 2.5,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}
