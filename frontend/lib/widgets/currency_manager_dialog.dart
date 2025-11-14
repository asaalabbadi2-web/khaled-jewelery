import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Data model
class Currency {
  String name;
  String symbol;
  double rate;
  bool isActive;

  Currency({
    required this.name,
    required this.symbol,
    required this.rate,
    this.isActive = false,
  });

  Map<String, dynamic> toJson() => {
    'name': name,
    'symbol': symbol,
    'rate': rate,
    'isActive': isActive,
  };

  factory Currency.fromJson(Map<String, dynamic> json) => Currency(
    name: json['name'],
    symbol: json['symbol'],
    rate: json['rate'],
    isActive: json['isActive'] ?? false,
  );
}

// The Dialog Widget
class CurrencyManagerDialog extends StatefulWidget {
  const CurrencyManagerDialog({super.key});

  @override
  _CurrencyManagerDialogState createState() => _CurrencyManagerDialogState();
}

class _CurrencyManagerDialogState extends State<CurrencyManagerDialog> {
  List<Currency> _currencies = [];
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _symbolController = TextEditingController();
  final _rateController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCurrencies();
  }

  Future<void> _loadCurrencies() async {
    final prefs = await SharedPreferences.getInstance();
    final String? currenciesString = prefs.getString('currencies');
    if (currenciesString != null) {
      final List<dynamic> currencyList = jsonDecode(currenciesString);
      setState(() {
        _currencies = currencyList
            .map((json) => Currency.fromJson(json))
            .toList();
      });
    } else {
      // Add a default currency if none exist
      setState(() {
        _currencies = [
          Currency(
            name: 'ريال سعودي',
            symbol: 'ر.س',
            rate: 3.75,
            isActive: true,
          ),
          Currency(
            name: 'دولار أمريكي',
            symbol: '\$',
            rate: 1.0,
            isActive: false,
          ),
        ];
        _saveCurrencies();
      });
    }
  }

  Future<void> _saveCurrencies() async {
    final prefs = await SharedPreferences.getInstance();
    final String currenciesString = jsonEncode(
      _currencies.map((c) => c.toJson()).toList(),
    );
    await prefs.setString('currencies', currenciesString);
  }

  void _setActiveCurrency(int index) {
    setState(() {
      for (int i = 0; i < _currencies.length; i++) {
        _currencies[i].isActive = (i == index);
      }
      _saveCurrencies();
    });
  }

  void _addCurrency() {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _currencies.add(
          Currency(
            name: _nameController.text,
            symbol: _symbolController.text,
            rate: double.parse(_rateController.text),
          ),
        );
        _saveCurrencies();
        _nameController.clear();
        _symbolController.clear();
        _rateController.clear();
        Navigator.of(context).pop(); // Close the add currency dialog
      });
    }
  }

  void _deleteCurrency(int index) {
    setState(() {
      if (_currencies[index].isActive && _currencies.length > 1) {
        // If deleting the active currency, make another one active
        _currencies.removeAt(index);
        _setActiveCurrency(0);
      } else if (_currencies.length > 1) {
        _currencies.removeAt(index);
      } else {
        // Don't allow deleting the last currency
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('لا يمكن حذف آخر عملة.')));
      }
      _saveCurrencies();
    });
  }

  void _showAddCurrencyDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('إضافة عملة جديدة'),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'اسم العملة'),
                validator: (v) => v!.isEmpty ? 'مطلوب' : null,
              ),
              TextFormField(
                controller: _symbolController,
                decoration: const InputDecoration(labelText: 'رمز العملة'),
                validator: (v) => v!.isEmpty ? 'مطلوب' : null,
              ),
              TextFormField(
                controller: _rateController,
                decoration: const InputDecoration(
                  labelText: 'سعر الصرف مقابل الدولار',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  NormalizeNumberFormatter(),
                  FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,4}')),
                ],
                validator: (v) =>
                    double.tryParse(v!) == null ? 'رقم غير صحيح' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('إلغاء'),
          ),
          ElevatedButton(onPressed: _addCurrency, child: const Text('إضافة')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إدارة العملات'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: _currencies.isEmpty
                  ? const Center(child: Text('لا توجد عملات.'))
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _currencies.length,
                      itemBuilder: (context, index) {
                        final currency = _currencies[index];
                        return ListTile(
                          title: Text('${currency.name} (${currency.symbol})'),
                          subtitle: Text(
                            '1 USD = ${currency.rate} ${currency.symbol}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: Icon(
                                  Icons.delete_outline,
                                  color: Colors.red.shade300,
                                ),
                                onPressed: () => _deleteCurrency(index),
                              ),
                              Switch(
                                value: currency.isActive,
                                onChanged: (val) => _setActiveCurrency(index),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            const Divider(),
            ElevatedButton.icon(
              onPressed: _showAddCurrencyDialog,
              icon: const Icon(Icons.add),
              label: const Text('إضافة عملة جديدة'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إغلاق'),
        ),
      ],
    );
  }
}
