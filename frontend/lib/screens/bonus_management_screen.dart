import 'package:flutter/material.dart';

import '../api_service.dart';
import '../theme/app_theme.dart';
import 'bonuses_screen.dart';
import 'bonus_rules_screen.dart';
import 'calculate_bonuses_screen.dart';

/// شاشة إدارة المكافآت تجمع الشاشات القديمة كما هي: المكافآت، القواعد، واحتساب المكافآت.
class BonusManagementScreen extends StatelessWidget {
  final ApiService api;
  final bool isArabic;

  const BonusManagementScreen({
    super.key,
    required this.api,
    this.isArabic = true,
  });

  @override
  Widget build(BuildContext context) {
    final isAr = isArabic;
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(isAr ? 'إدارة المكافآت' : 'Bonus Management'),
          backgroundColor: AppColors.darkGold,
          bottom: TabBar(
            labelColor: Colors.black,
            indicatorColor: AppColors.darkGold,
            tabs: [
              Tab(
                text: isAr ? 'المكافآت' : 'Bonuses',
                icon: const Icon(Icons.card_giftcard),
              ),
              Tab(
                text: isAr ? 'القواعد' : 'Rules',
                icon: const Icon(Icons.rule),
              ),
              Tab(
                text: isAr ? 'احتساب' : 'Calculate',
                icon: const Icon(Icons.calculate),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            BonusesScreen(api: api, isArabic: isAr),
            BonusRulesScreen(api: api, isArabic: isAr, embedded: true),
            CalculateBonusesScreen(api: api, isArabic: isAr),
          ],
        ),
      ),
    );
  }
}
