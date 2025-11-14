/// نموذج صنف في الفاتورة مع دعم immutability و serialization
class InvoiceItemRow {
  // --- بيانات الصنف الأساسية ---
  final int? itemId;
  final String itemName;
  final String? barcode; // دعم الباركود
  final String? imageUrl; // صورة الصنف

  // --- المواصفات ---
  final double karat;
  final double weight;
  final double wage;
  final bool isWagePerGram;
  final int count;

  // --- التسعير اليدوي (اختياري) ---
  final double? sellingPricePerGram;
  final double? manualTotal;

  // --- القيم المحسوبة ---
  final double cost;
  final double tax;
  final double net;
  final double total;
  final double calculatedSellingPricePerGram;

  const InvoiceItemRow({
    this.itemId,
    this.itemName = '',
    this.barcode,
    this.imageUrl,
    this.karat = 21.0,
    this.weight = 0.0,
    this.wage = 0.0,
    this.isWagePerGram = true,
    this.count = 1,
    this.sellingPricePerGram,
    this.manualTotal,
    this.cost = 0.0,
    this.tax = 0.0,
    this.net = 0.0,
    this.total = 0.0,
    this.calculatedSellingPricePerGram = 0.0,
  });

  /// الأجرة الإجمالية حسب نوع الحساب
  double get totalWage {
    if (isWagePerGram) {
      return wage * weight;
    } else {
      return wage;
    }
  }

  /// الوزن الإجمالي (مع الكمية)
  double get totalWeight => weight * count;

  /// التحقق من وجود قيم يدوية
  bool get hasManualOverride =>
      (sellingPricePerGram != null && sellingPricePerGram! > 0) ||
      (manualTotal != null && manualTotal! > 0);

  /// إنشاء نسخة معدلة
  InvoiceItemRow copyWith({
    int? itemId,
    String? itemName,
    String? barcode,
    String? imageUrl,
    double? karat,
    double? weight,
    double? wage,
    bool? isWagePerGram,
    int? count,
    double? sellingPricePerGram,
    double? manualTotal,
    double? cost,
    double? tax,
    double? net,
    double? total,
    double? calculatedSellingPricePerGram,
  }) {
    return InvoiceItemRow(
      itemId: itemId ?? this.itemId,
      itemName: itemName ?? this.itemName,
      barcode: barcode ?? this.barcode,
      imageUrl: imageUrl ?? this.imageUrl,
      karat: karat ?? this.karat,
      weight: weight ?? this.weight,
      wage: wage ?? this.wage,
      isWagePerGram: isWagePerGram ?? this.isWagePerGram,
      count: count ?? this.count,
      sellingPricePerGram: sellingPricePerGram,
      manualTotal: manualTotal,
      cost: cost ?? this.cost,
      tax: tax ?? this.tax,
      net: net ?? this.net,
      total: total ?? this.total,
      calculatedSellingPricePerGram:
          calculatedSellingPricePerGram ?? this.calculatedSellingPricePerGram,
    );
  }

  /// إنشاء نسخة مع حسابات محدثة
  InvoiceItemRow withCalculations({
    required double goldPrice24k,
    required double exchangeRate,
    required double taxRate,
  }) {
    // أولوية 1: إجمالي يدوي
    if (manualTotal != null && manualTotal! > 0) {
      final calculatedTotal = manualTotal!;
      final calculatedNet = calculatedTotal / (1 + taxRate);
      final calculatedTax = calculatedTotal - calculatedNet;
      final calculatedPricePerGram = weight > 0 ? calculatedNet / weight : 0.0;

      return copyWith(
        total: calculatedTotal,
        net: calculatedNet,
        tax: calculatedTax,
        cost: calculatedNet,
        calculatedSellingPricePerGram: calculatedPricePerGram,
        sellingPricePerGram: null,
      );
    }

    // أولوية 2: سعر البيع لكل جرام يدوي
    if (sellingPricePerGram != null && sellingPricePerGram! > 0) {
      final calculatedNet = sellingPricePerGram! * weight;
      final calculatedTax = calculatedNet * taxRate;
      final calculatedTotal = calculatedNet + calculatedTax;

      return copyWith(
        net: calculatedNet,
        cost: calculatedNet,
        tax: calculatedTax,
        total: calculatedTotal,
        calculatedSellingPricePerGram: sellingPricePerGram!,
        manualTotal: null,
      );
    }

    // أولوية 3: حساب تلقائي
    if (weight <= 0 || goldPrice24k <= 0) {
      return copyWith(
        cost: 0.0,
        tax: 0.0,
        net: 0.0,
        total: 0.0,
        calculatedSellingPricePerGram: 0.0,
      );
    }

    final goldPriceForKaratUSD = (goldPrice24k / 24.0) * karat;
    final goldPriceForKaratLocal = goldPriceForKaratUSD * exchangeRate;
    final calculatedNet = (goldPriceForKaratLocal * weight) + totalWage;
    final calculatedTax = calculatedNet * taxRate;
    final calculatedTotal = calculatedNet + calculatedTax;
    final calculatedPricePerGram = weight > 0 ? calculatedNet / weight : 0.0;

    return copyWith(
      net: calculatedNet,
      cost: calculatedNet,
      tax: calculatedTax,
      total: calculatedTotal,
      calculatedSellingPricePerGram: calculatedPricePerGram,
      sellingPricePerGram: null,
      manualTotal: null,
    );
  }

  /// تحويل من JSON
  factory InvoiceItemRow.fromJson(Map<String, dynamic> json) {
    return InvoiceItemRow(
      itemId: json['item_id'] as int?,
      itemName: json['name'] as String? ?? '',
      barcode: json['barcode'] as String?,
      imageUrl: json['image_url'] as String?,
      karat: (json['karat'] as num?)?.toDouble() ?? 21.0,
      weight: (json['weight'] as num?)?.toDouble() ?? 0.0,
      wage: (json['wage'] as num?)?.toDouble() ?? 0.0,
      isWagePerGram: json['is_wage_per_gram'] as bool? ?? true,
      count: json['quantity'] as int? ?? 1,
      sellingPricePerGram: (json['selling_price_per_gram'] as num?)?.toDouble(),
      manualTotal: (json['manual_total'] as num?)?.toDouble(),
      cost: (json['cost'] as num?)?.toDouble() ?? 0.0,
      tax: (json['tax'] as num?)?.toDouble() ?? 0.0,
      net: (json['net'] as num?)?.toDouble() ?? 0.0,
      total: (json['total'] as num?)?.toDouble() ?? 0.0,
      calculatedSellingPricePerGram:
          (json['calculated_selling_price_per_gram'] as num?)?.toDouble() ??
          0.0,
    );
  }

  /// تحويل إلى JSON
  Map<String, dynamic> toJson() {
    return {
      'item_id': itemId,
      'name': itemName,
      'barcode': barcode,
      'image_url': imageUrl,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      'is_wage_per_gram': isWagePerGram,
      'quantity': count,
      'selling_price_per_gram': sellingPricePerGram,
      'manual_total': manualTotal,
      'cost': cost,
      'tax': tax,
      'net': net,
      'total': total,
      'calculated_selling_price_per_gram': calculatedSellingPricePerGram,
    };
  }

  /// تحويل إلى JSON للإرسال للـ Backend
  Map<String, dynamic> toBackendJson() {
    return {
      'item_id': itemId,
      'name': itemName,
      'barcode': barcode,
      'quantity': count,
      'price': total,
      'karat': karat,
      'weight': weight,
      'wage': wage,
      'net': net,
      'tax': tax,
    };
  }
}
