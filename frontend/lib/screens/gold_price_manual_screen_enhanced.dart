import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../utils.dart';

/// شاشة تحديث سعر الذهب المحسّنة بتصميم احترافي
class GoldPriceManualScreenEnhanced extends StatefulWidget {
  const GoldPriceManualScreenEnhanced({super.key});

  @override
  State<GoldPriceManualScreenEnhanced> createState() =>
      _GoldPriceManualScreenEnhancedState();
}

class _GoldPriceManualScreenEnhancedState
    extends State<GoldPriceManualScreenEnhanced> {
  final TextEditingController _priceController = TextEditingController();
  final TextEditingController _priceUsdController = TextEditingController();
  final ApiService _apiService = ApiService();

  bool _isLoading = true;
  bool _isUpdating = false;
  bool _useUsdInput = false;
  double? _currentPrice;
  DateTime? _lastUpdateDate;
  final List<Map<String, dynamic>> _priceHistory = [];

  // ألوان النظام
  final Color _goldColor = const Color(0xFFFFD700);
  final Color _successColor = const Color(0xFF4CAF50);
  final Color _warningColor = const Color(0xFFFF9800);
  final Color _errorColor = const Color(0xFFF44336);
  final Color _accentColor = const Color(0xFF1976D2);

  @override
  void initState() {
    super.initState();
    _loadCurrentPrice();
  }

  @override
  void dispose() {
    _priceController.dispose();
    _priceUsdController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentPrice() async {
    setState(() => _isLoading = true);
    try {
      final priceData = await _apiService.getGoldPrice();

      setState(() {
        final raw = priceData['price_sar_per_gram'] ?? priceData['price_24k'];
        _currentPrice = raw is num ? raw.toDouble() : double.tryParse('$raw');
        _lastUpdateDate = priceData['date'] != null
            ? DateTime.parse(priceData['date'])
            : null;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
      _showMessage('فشل تحميل السعر: $e', isError: true);
    }
  }

  Future<void> _updatePrice() async {
    if (!_useUsdInput && _priceController.text.isEmpty) {
      _showMessage(
        'يرجى إدخال سعر الغرام بالريال أو التبديل إلى الدولار/أونصة',
        isError: true,
      );
      return;
    }
    if (_useUsdInput && _priceUsdController.text.isEmpty) {
      _showMessage(
        'يرجى إدخال سعر الأونصة بالدولار أو إلغاء التبديل',
        isError: true,
      );
      return;
    }

    final sarValue = double.tryParse(_priceController.text);
    final usdValue = double.tryParse(_priceUsdController.text);

    if (!_useUsdInput && (sarValue == null || sarValue <= 0)) {
      _showMessage('يرجى إدخال سعر غرام صحيح', isError: true);
      return;
    }
    if (_useUsdInput && (usdValue == null || usdValue <= 0)) {
      _showMessage('يرجى إدخال سعر أونصة صحيح', isError: true);
      return;
    }

    final double newSarPerGram = _useUsdInput
        ? _usdToSar(usdValue!)
        : sarValue!;

    // تأكيد التحديث
    final confirm = await _showConfirmDialog(newSarPerGram);
    if (!confirm) return;

    setState(() => _isUpdating = true);

    try {
      final oldPrice = _currentPrice;

      // Backend stores gold price as USD/oz. Convert when user inputs SAR/gram.
      final double priceUsdPerOz = _useUsdInput
          ? usdValue!
          : _sarToUsdPerOz(sarValue!);

      await _apiService.updateGoldPrice(priceUsdPerOz: priceUsdPerOz);
      await _loadCurrentPrice();

      setState(() {
        _priceHistory.insert(0, {
          'price': _currentPrice,
          'old_price': oldPrice,
          'date': DateTime.now(),
        });
        if (_useUsdInput) {
          _priceUsdController.clear();
        } else {
          _priceController.clear();
        }
        _isUpdating = false;
      });

      _showMessage('✅ تم تحديث السعر بنجاح');
    } catch (e) {
      setState(() => _isUpdating = false);
      _showMessage('فشل التحديث: $e', isError: true);
    }
  }

  double _usdToSar(double priceUsdPerOz) {
    return (priceUsdPerOz / 31.1035) * 3.75;
  }

  double _sarToUsdPerOz(double priceSarPerGram) {
    return (priceSarPerGram / 3.75) * 31.1035;
  }

  Future<void> _instantUpdateFromInternet() async {
    setState(() => _isUpdating = true);
    try {
      final oldPrice = _currentPrice;
      await _apiService.updateGoldPrice();
      await _loadCurrentPrice();
      setState(() {
        _priceHistory.insert(0, {
          'price': _currentPrice,
          'old_price': oldPrice,
          'date': DateTime.now(),
        });
        _isUpdating = false;
      });
      _showMessage('✅ تم تحديث السعر من الإنترنت');
    } catch (e) {
      setState(() => _isUpdating = false);
      _showMessage('فشل التحديث من الإنترنت: $e', isError: true);
    }
  }

  Future<bool> _showConfirmDialog(double newPriceSarPerGram) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: _warningColor,
                  size: 28,
                ),
                SizedBox(width: 12),
                Text(
                  'تأكيد التحديث',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ],
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('هل أنت متأكد من تحديث سعر الذهب؟'),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    children: [
                      if (_currentPrice != null) ...[
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'السعر الحالي:',
                              style: TextStyle(fontSize: 14),
                            ),
                            Text(
                              '${_currentPrice!.toStringAsFixed(2)} ر.س/غ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.grey.shade700,
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: 8),
                      ],
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text('السعر الجديد:', style: TextStyle(fontSize: 14)),
                          Text(
                            '${newPriceSarPerGram.toStringAsFixed(2)} ر.س/غ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _goldColor,
                              fontSize: 16,
                            ),
                          ),
                        ],
                      ),
                      if (_currentPrice != null) ...[
                        SizedBox(height: 8),
                        Divider(),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text('الفرق:', style: TextStyle(fontSize: 14)),
                            Text(
                              '${(newPriceSarPerGram - _currentPrice!).toStringAsFixed(2)} ر.س/غ',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: newPriceSarPerGram > _currentPrice!
                                    ? _successColor
                                    : _errorColor,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('إلغاء'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.pop(context, true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _goldColor,
                  foregroundColor: Colors.black87,
                ),
                child: Text('تأكيد التحديث'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showMessage(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              isError ? Icons.error_outline : Icons.check_circle_outline,
              color: Colors.white,
            ),
            SizedBox(width: 12),
            Expanded(child: Text(message, style: TextStyle(fontSize: 15))),
          ],
        ),
        backgroundColor: isError ? _errorColor : _successColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: Duration(seconds: isError ? 4 : 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade50,
      appBar: AppBar(
        elevation: 0,
        title: Row(
          children: [
            Icon(Icons.monetization_on, color: Colors.white, size: 28),
            SizedBox(width: 12),
            Text(
              'تحديث سعر الذهب',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 22,
                color: Colors.white,
              ),
            ),
          ],
        ),
        flexibleSpace: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [_goldColor, Color.lerp(_goldColor, _accentColor, 0.3)!],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
        ),
        actions: [
          IconButton(
            onPressed: _loadCurrentPrice,
            icon: Icon(Icons.refresh, color: Colors.white),
            tooltip: 'تحديث',
          ),
        ],
      ),
      body: _isLoading
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(_goldColor),
                    strokeWidth: 3,
                  ),
                  SizedBox(height: 20),
                  Text(
                    'جاري تحميل السعر الحالي...',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            )
          : SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // بطاقة السعر الحالي
                  _buildCurrentPriceCard(),

                  SizedBox(height: 20),

                  // بطاقة تحديث السعر
                  _buildUpdatePriceCard(),

                  SizedBox(height: 20),

                  // معلومات إضافية
                  _buildInfoCard(),

                  SizedBox(height: 20),

                  // سجل التحديثات
                  if (_priceHistory.isNotEmpty) _buildHistoryCard(),
                ],
              ),
            ),
    );
  }

  Widget _buildCurrentPriceCard() {
    return Card(
      elevation: 4,
      shadowColor: _goldColor.withValues(alpha: 0.3),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: _goldColor.withValues(alpha: 0.3), width: 2),
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [_goldColor.withValues(alpha: 0.1), Colors.white],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: _goldColor.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.diamond, color: _goldColor, size: 32),
                ),
                SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'السعر الحالي للذهب',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          color: Colors.grey.shade700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        _currentPrice != null
                            ? '${_currentPrice!.toStringAsFixed(2)} ر.س'
                            : 'غير متوفر',
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color: _goldColor,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'للغرام الواحد',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            if (_lastUpdateDate != null) ...[
              SizedBox(height: 16),
              Divider(),
              SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.access_time,
                    size: 16,
                    color: Colors.grey.shade600,
                  ),
                  SizedBox(width: 8),
                  Text(
                    'آخر تحديث: ${DateFormat('dd/MM/yyyy - hh:mm a', 'ar').format(_lastUpdateDate!)}',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  // NOTE: _buildUpdatePriceCard exists below; we inject a small instant-update action.

  Widget _buildUpdatePriceCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: LinearGradient(
            colors: [Colors.white, Colors.grey.shade50],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        padding: EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: _accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.edit, color: _accentColor, size: 28),
                ),
                SizedBox(width: 12),
                Text(
                  'تحديث السعر',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),

            SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton.icon(
                onPressed: _isUpdating ? null : _instantUpdateFromInternet,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _accentColor,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                icon: const Icon(Icons.sync_rounded),
                label: const Text(
                  'تحديث فوري من الإنترنت',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),

            SizedBox(height: 12),

            Container(
              padding: EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.blue.shade200),
              ),
              child: Row(
                children: [
                  Icon(Icons.swap_horiz, color: _accentColor, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _useUsdInput
                          ? 'أدخل سعر الأونصة بالدولار الأمريكي'
                          : 'أدخل سعر الغرام الواحد بالريال السعودي',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey.shade700,
                      ),
                    ),
                  ),
                  Switch(
                    value: _useUsdInput,
                    activeThumbColor: _accentColor,
                    onChanged: (value) {
                      setState(() {
                        _useUsdInput = value;
                        _priceController.clear();
                        _priceUsdController.clear();
                      });
                    },
                  ),
                ],
              ),
            ),

            SizedBox(height: 20),

            if (!_useUsdInput)
              TextFormField(
                controller: _priceController,
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [NormalizeNumberFormatter()],
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'سعر الغرام الجديد',
                  labelStyle: TextStyle(
                    color: _goldColor,
                    fontWeight: FontWeight.bold,
                  ),
                  hintText: 'مثال: 250.50',
                  prefixIcon: Icon(Icons.monetization_on, color: _goldColor),
                  suffixText: 'ر.س',
                  suffixStyle: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _goldColor, width: 2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 2,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: _goldColor, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            if (_useUsdInput)
              TextFormField(
                controller: _priceUsdController,
                keyboardType: TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [NormalizeNumberFormatter()],
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                decoration: InputDecoration(
                  labelText: 'سعر الأونصة بالدولار',
                  labelStyle: TextStyle(
                    color: Colors.blueGrey,
                    fontWeight: FontWeight.bold,
                  ),
                  hintText: 'مثال: 2350.00',
                  prefixIcon: Icon(Icons.attach_money, color: Colors.blueGrey),
                  suffixText: 'USD',
                  suffixStyle: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade600,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.blueGrey, width: 2),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(
                      color: Colors.grey.shade300,
                      width: 2,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Colors.blueGrey, width: 2),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),

            SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton(
                onPressed: _isUpdating ? null : _updatePrice,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _goldColor,
                  foregroundColor: Colors.black87,
                  elevation: 4,
                  shadowColor: _goldColor.withValues(alpha: 0.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _isUpdating
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(
                                Colors.black87,
                              ),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text(
                            'جاري التحديث...',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.save, size: 24),
                          SizedBox(width: 12),
                          Text(
                            'تحديث السعر',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard() {
    return Container(
      padding: EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.orange.shade50, Colors.white],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: _warningColor.withValues(alpha: 0.3),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lightbulb_outline, color: _warningColor, size: 24),
              SizedBox(width: 8),
              Text(
                'معلومات هامة',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _warningColor,
                ),
              ),
            ],
          ),
          SizedBox(height: 16),
          _buildInfoRow('⚠️', 'تأكد من صحة السعر قبل التحديث'),
          _buildInfoRow('💡', 'السعر سيؤثر على جميع الحسابات والفواتير'),
          _buildInfoRow('📊', 'يمكنك مراجعة سجل التحديثات أدناه'),
          _buildInfoRow('🔄', 'يمكن التحديث في أي وقت'),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String emoji, String text) {
    return Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(emoji, style: TextStyle(fontSize: 16)),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade700,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHistoryCard() {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.history, color: _accentColor, size: 24),
                SizedBox(width: 8),
                Text(
                  'سجل التحديثات',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
            SizedBox(height: 16),
            ListView.separated(
              shrinkWrap: true,
              physics: NeverScrollableScrollPhysics(),
              itemCount: _priceHistory.length > 5 ? 5 : _priceHistory.length,
              separatorBuilder: (context, index) => Divider(height: 24),
              itemBuilder: (context, index) {
                final record = _priceHistory[index];
                final price = record['price'] as double;
                final oldPrice = record['old_price'] as double?;
                final date = record['date'] as DateTime;
                final diff = oldPrice != null ? price - oldPrice : 0.0;

                return Row(
                  children: [
                    Container(
                      padding: EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: diff > 0
                            ? _successColor.withValues(alpha: 0.1)
                            : diff < 0
                            ? _errorColor.withValues(alpha: 0.1)
                            : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        diff > 0
                            ? Icons.trending_up
                            : diff < 0
                            ? Icons.trending_down
                            : Icons.remove,
                        color: diff > 0
                            ? _successColor
                            : diff < 0
                            ? _errorColor
                            : Colors.grey,
                        size: 20,
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${price.toStringAsFixed(2)} ر.س/غ',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            DateFormat(
                              'dd/MM/yyyy - hh:mm a',
                              'ar',
                            ).format(date),
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (oldPrice != null)
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: diff > 0
                              ? _successColor.withValues(alpha: 0.1)
                              : _errorColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${diff > 0 ? '+' : ''}${diff.toStringAsFixed(2)}',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: diff > 0 ? _successColor : _errorColor,
                          ),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
