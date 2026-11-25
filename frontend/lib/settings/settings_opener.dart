import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../screens/accounting_mapping_screen_enhanced.dart';
import '../screens/accounts_screen.dart';
import '../screens/audit_log_screen.dart';
import '../screens/backup_restore_screen.dart';
import '../screens/bonus_rules_screen.dart';
import '../screens/branches_management_screen.dart';
import '../screens/categories_screen.dart';
import '../screens/gold_price_manual_screen_enhanced.dart';
import '../screens/import_documents_screen.dart';
import '../screens/item_sections_screen.dart';
import '../screens/label_printers_screen.dart';
import '../screens/payment_methods_screen_enhanced.dart';
import '../screens/payroll_policy_screen.dart';
import '../screens/period_lock_screen.dart';
import '../screens/posting_management_screen.dart';
import '../screens/safe_boxes_screen.dart';
import '../screens/sales_race_management_screen.dart';
import '../screens/security_sessions_screen.dart';
import '../screens/settings_screen_enhanced.dart';
import '../screens/size_systems_screen.dart';
import '../screens/supplier_settlement_policy_screen.dart';
import '../screens/system_reset_screen.dart';
import '../screens/users_screen.dart';
import '../screens/weight_closing_settings_screen.dart';
import 'settings_registry.dart';

/// Opens what an entry is set in: the old settings screen on its tab, or the
/// screen that owns it -- each opened as everywhere else opens it (spec v2
/// §0: the center links, it owns no screen's logic).
typedef SettingsOpener = Future<void> Function(BuildContext context, SettingEntry entry);

/// Every screen id the registry may name, and how it is opened.
final Map<String, Widget Function(BuildContext context, ApiService api)> settingsScreens = {
  'branches': (_, _) => const BranchesManagementScreen(isArabic: true),
  'gold_price_manual': (_, _) => const GoldPriceManualScreenEnhanced(),
  'weight_closing': (_, _) => const WeightClosingSettingsScreen(),
  'payment_methods': (_, _) => const PaymentMethodsScreenEnhanced(),
  'safe_boxes': (_, _) => SafeBoxesScreen(),
  'posting': (_, _) => const PostingManagementScreen(isArabic: true),
  'supplier_settlement_policy': (_, api) => SupplierSettlementPolicyScreen(api: api, isArabic: true),
  'accounting_mapping': (_, _) => const AccountingMappingScreenEnhanced(),
  'accounts': (_, _) => AccountsScreen(),
  'period_lock': (context, api) => PeriodLockScreen(
        api: api,
        canMove: context.read<AuthProvider>().hasPermission('accounting.period_lock'),
      ),
  'categories': (_, api) => CategoriesScreen(api: api),
  'item_sections': (_, api) => ItemSectionsScreen(api: api),
  'size_systems': (_, api) => SizeSystemsScreen(api: api),
  'label_printers': (_, api) => LabelPrintersScreen(api: api),
  'payroll_policy': (_, api) => PayrollPolicyScreen(api: api, isArabic: true),
  'bonus_rules': (_, api) => BonusRulesScreen(api: api),
  'sales_race': (_, api) => SalesRaceManagementScreen(api: api, isArabic: true),
  'users': (_, api) => UsersScreen(api: api, isArabic: true),
  'sessions': (_, _) => const SecuritySessionsScreen(),
  'audit_log': (_, _) => const AuditLogScreen(),
  'backup': (_, _) => const BackupRestoreScreen(isArabic: true),
  'import_excel': (_, _) => const ImportDocumentsScreen(isArabic: true),
  'system_reset': (_, _) => const SystemResetScreen(),
};

/// The old screen's tab names, said where an entry is set until its section
/// page replaces them.
const legacyTabNames = ['عام', 'الشركة والفواتير', 'المدفوعات', 'محاسبة', 'الطباعة', 'النظام'];

Future<void> openSettingEntry(BuildContext context, SettingEntry entry) async {
  final Widget page;
  if (entry.screen != null) {
    page = settingsScreens[entry.screen]!(context, ApiService());
  } else {
    page = SettingsScreenEnhanced(initialTabIndex: entry.legacyTab ?? 0);
  }
  await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
}
