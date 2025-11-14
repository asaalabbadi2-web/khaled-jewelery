/// نظام التحقق من صحة بيانات الفاتورة
class InvoiceFormValidator {
  // --- قواعد التحقق من الأصناف ---

  /// التحقق من الوزن
  static String? validateWeight(String? value, {bool allowZero = false}) {
    if (value == null || value.isEmpty) {
      return 'الوزن مطلوب';
    }

    final weight = double.tryParse(value);
    if (weight == null) {
      return 'يرجى إدخال رقم صحيح';
    }

    if (!allowZero && weight <= 0) {
      return 'الوزن يجب أن يكون أكبر من صفر';
    }

    if (weight < 0) {
      return 'الوزن لا يمكن أن يكون سالباً';
    }

    if (weight > 10000) {
      return '⚠️ الوزن كبير جداً - يرجى التحقق';
    }

    return null;
  }

  /// التحقق من العيار
  static String? validateKarat(String? value) {
    if (value == null || value.isEmpty) {
      return 'العيار مطلوب';
    }

    final karat = double.tryParse(value);
    if (karat == null) {
      return 'يرجى إدخال رقم صحيح';
    }

    if (karat <= 0) {
      return 'العيار يجب أن يكون أكبر من صفر';
    }

    if (karat > 24) {
      return 'العيار لا يمكن أن يكون أكبر من 24';
    }

    // عيارات شائعة
    final commonKarats = [18.0, 21.0, 22.0, 24.0];
    if (!commonKarats.contains(karat)) {
      return '⚠️ عيار غير شائع - يرجى التأكد';
    }

    return null;
  }

  /// التحقق من المصنعية
  static String? validateWage(String? value, {bool allowZero = true}) {
    if (value == null || value.isEmpty) {
      return allowZero ? null : 'المصنعية مطلوبة';
    }

    final wage = double.tryParse(value);
    if (wage == null) {
      return 'يرجى إدخال رقم صحيح';
    }

    if (wage < 0) {
      return 'المصنعية لا يمكن أن تكون سالبة';
    }

    if (wage > 100000) {
      return '⚠️ المصنعية كبيرة جداً - يرجى التحقق';
    }

    return null;
  }

  /// التحقق من الكمية
  static String? validateQuantity(String? value) {
    if (value == null || value.isEmpty) {
      return 'الكمية مطلوبة';
    }

    final quantity = int.tryParse(value);
    if (quantity == null) {
      return 'يرجى إدخال رقم صحيح';
    }

    if (quantity <= 0) {
      return 'الكمية يجب أن تكون أكبر من صفر';
    }

    if (quantity > 1000) {
      return '⚠️ الكمية كبيرة جداً - يرجى التحقق';
    }

    return null;
  }

  /// التحقق من السعر
  static String? validatePrice(String? value, {bool allowZero = false}) {
    if (value == null || value.isEmpty) {
      return allowZero ? null : 'السعر مطلوب';
    }

    final price = double.tryParse(value);
    if (price == null) {
      return 'يرجى إدخال رقم صحيح';
    }

    if (!allowZero && price <= 0) {
      return 'السعر يجب أن يكون أكبر من صفر';
    }

    if (price < 0) {
      return 'السعر لا يمكن أن يكون سالباً';
    }

    return null;
  }

  // --- قواعد التحقق من العميل ---

  /// التحقق من اختيار العميل
  static String? validateCustomerSelection(int? customerId) {
    if (customerId == null) {
      return 'يرجى اختيار عميل';
    }
    return null;
  }

  /// التحقق من اسم العميل
  static String? validateCustomerName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'اسم العميل مطلوب';
    }

    if (value.trim().length < 2) {
      return 'الاسم قصير جداً';
    }

    if (value.trim().length > 100) {
      return 'الاسم طويل جداً';
    }

    return null;
  }

  /// التحقق من رقم الجوال
  static String? validatePhone(String? value, {bool required = false}) {
    if (value == null || value.trim().isEmpty) {
      return required ? 'رقم الجوال مطلوب' : null;
    }

    // إزالة المسافات والرموز
    final cleanPhone = value.replaceAll(RegExp(r'[\s\-\(\)]'), '');

    // التحقق من الأرقام فقط
    if (!RegExp(r'^[0-9+]+$').hasMatch(cleanPhone)) {
      return 'رقم الجوال يجب أن يحتوي على أرقام فقط';
    }

    // التحقق من الطول (السعودية: 10 أرقام أو +966...)
    if (cleanPhone.length < 9 || cleanPhone.length > 15) {
      return 'رقم الجوال غير صحيح';
    }

    return null;
  }

  /// التحقق من البريد الإلكتروني
  static String? validateEmail(String? value, {bool required = false}) {
    if (value == null || value.trim().isEmpty) {
      return required ? 'البريد الإلكتروني مطلوب' : null;
    }

    final emailRegex = RegExp(
      r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$',
    );

    if (!emailRegex.hasMatch(value.trim())) {
      return 'البريد الإلكتروني غير صحيح';
    }

    return null;
  }

  // --- قواعد التحقق من الدفع ---

  /// التحقق من المبلغ المدفوع
  static String? validateAmountPaid(
    String? value,
    double grandTotal, {
    bool allowPartial = true,
  }) {
    if (value == null || value.isEmpty) {
      return allowPartial ? null : 'المبلغ المدفوع مطلوب';
    }

    final amountPaid = double.tryParse(value);
    if (amountPaid == null) {
      return 'يرجى إدخال رقم صحيح';
    }

    if (amountPaid < 0) {
      return 'المبلغ لا يمكن أن يكون سالباً';
    }

    if (amountPaid > grandTotal) {
      return 'المبلغ المدفوع لا يمكن أن يكون أكبر من الإجمالي';
    }

    return null;
  }

  /// التحقق من طريقة الدفع
  static String? validatePaymentMethod(String? value) {
    if (value == null || value.isEmpty) {
      return 'يرجى اختيار طريقة الدفع';
    }

    final validMethods = ['cash', 'credit', 'bank_transfer', 'check'];
    if (!validMethods.contains(value)) {
      return 'طريقة الدفع غير صحيحة';
    }

    return null;
  }

  // --- قواعد التحقق من الباركود ---

  /// التحقق من صحة الباركود
  static String? validateBarcode(String? value, {bool required = false}) {
    if (value == null || value.trim().isEmpty) {
      return required ? 'الباركود مطلوب' : null;
    }

    final cleanBarcode = value.trim();

    // التحقق من الطول المعقول
    if (cleanBarcode.length < 3 || cleanBarcode.length > 50) {
      return 'الباركود غير صحيح';
    }

    // قد نضيف قواعد أكثر تحديداً حسب نوع الباركود المستخدم

    return null;
  }

  // --- قواعد عامة ---

  /// التحقق من وجود أصناف في الفاتورة
  static String? validateInvoiceItems(List items) {
    if (items.isEmpty) {
      return 'يرجى إضافة صنف واحد على الأقل';
    }

    return null;
  }

  /// التحقق من إجمالي الفاتورة
  static String? validateGrandTotal(double total) {
    if (total <= 0) {
      return 'إجمالي الفاتورة يجب أن يكون أكبر من صفر';
    }

    if (total > 10000000) {
      return '⚠️ إجمالي الفاتورة كبير جداً - يرجى التحقق';
    }

    return null;
  }
}
