/// أنواع تدفقات الفواتير المدعومة في النظام.
enum InvoiceFlowType {
  saleNew,
  saleScrap,
  purchaseScrapCustomer,
  purchaseNewSupplier,
}

/// إعدادات سلوكية لتحديد طريقة عمل شاشة الفاتورة.
class InvoiceFlowConfig {
  final InvoiceFlowType type;
  final String invoiceType;
  final String transactionType;
  final String goldType;
  final bool requiresIdentity;
  final bool allowsTax;
  final bool supportsCashPayments;
  final bool supportsGoldSettlement;
  final double defaultTaxRate;
  final String screenTitle;
  final String submitLabel;

  const InvoiceFlowConfig({
    required this.type,
    required this.invoiceType,
    required this.transactionType,
    required this.goldType,
    required this.requiresIdentity,
    required this.allowsTax,
    required this.supportsCashPayments,
    required this.supportsGoldSettlement,
    required this.defaultTaxRate,
    required this.screenTitle,
    required this.submitLabel,
  });

  /// تكوين افتراضي لواجهة فاتورة بيع الذهب الكسر.
  factory InvoiceFlowConfig.scrapSale() {
    return const InvoiceFlowConfig(
      type: InvoiceFlowType.saleScrap,
      invoiceType: 'بيع',
      transactionType: 'sell',
      goldType: 'scrap',
      requiresIdentity: false,
      allowsTax: false,
      supportsCashPayments: false,
      supportsGoldSettlement: true,
      defaultTaxRate: 0.0,
      screenTitle: 'فاتورة بيع ذهب كسر',
      submitLabel: 'إصدار الفاتورة',
    );
  }

  /// تكوين افتراضي لواجهة فاتورة شراء كسر من العميل.
  factory InvoiceFlowConfig.scrapPurchase() {
    return const InvoiceFlowConfig(
      type: InvoiceFlowType.purchaseScrapCustomer,
      invoiceType: 'شراء',
      transactionType: 'buy',
      goldType: 'scrap',
      requiresIdentity: true, // إلزامي: رقم الهوية، إصدارها، تاريخ الميلاد
      allowsTax: false,
      supportsCashPayments: true, // دفع نقدي أو بنك
      supportsGoldSettlement: false,
      defaultTaxRate: 0.0,
      screenTitle: 'فاتورة شراء ذهب كسر',
      submitLabel: 'إصدار فاتورة الشراء',
    );
  }

  /// تكوين افتراضي لواجهة فاتورة شراء جديد من المورد.
  factory InvoiceFlowConfig.newPurchase() {
    return const InvoiceFlowConfig(
      type: InvoiceFlowType.purchaseNewSupplier,
      invoiceType: 'شراء',
      transactionType: 'buy',
      goldType: 'new',
      requiresIdentity: false, // المورد مسجل مسبقاً
      allowsTax: true,
      supportsCashPayments: true, // دفع نقدي يُنشئ فاتورة كسر
      supportsGoldSettlement: true, // ذهب مقابل ذهب + أجور
      defaultTaxRate: 0.15,
      screenTitle: 'فاتورة شراء ذهب جديد',
      submitLabel: 'إصدار فاتورة الشراء',
    );
  }

  InvoiceFlowConfig copyWith({
    InvoiceFlowType? type,
    String? invoiceType,
    String? transactionType,
    String? goldType,
    bool? requiresIdentity,
    bool? allowsTax,
    bool? supportsCashPayments,
    bool? supportsGoldSettlement,
    double? defaultTaxRate,
    String? screenTitle,
    String? submitLabel,
  }) {
    return InvoiceFlowConfig(
      type: type ?? this.type,
      invoiceType: invoiceType ?? this.invoiceType,
      transactionType: transactionType ?? this.transactionType,
      goldType: goldType ?? this.goldType,
      requiresIdentity: requiresIdentity ?? this.requiresIdentity,
      allowsTax: allowsTax ?? this.allowsTax,
      supportsCashPayments: supportsCashPayments ?? this.supportsCashPayments,
      supportsGoldSettlement:
          supportsGoldSettlement ?? this.supportsGoldSettlement,
      defaultTaxRate: defaultTaxRate ?? this.defaultTaxRate,
      screenTitle: screenTitle ?? this.screenTitle,
      submitLabel: submitLabel ?? this.submitLabel,
    );
  }
}
