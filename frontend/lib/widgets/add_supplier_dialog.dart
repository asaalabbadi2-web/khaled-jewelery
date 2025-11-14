import 'package:flutter/material.dart';
import '../api_service.dart';

class AddSupplierDialog extends StatefulWidget {
  final ApiService api;

  const AddSupplierDialog({super.key, required this.api});

  @override
  _AddSupplierDialogState createState() => _AddSupplierDialogState();
}

class _AddSupplierDialogState extends State<AddSupplierDialog> {
  final _formKey = GlobalKey<FormState>();
  String _name = '';
  String _phone = '';
  String _email = '';
  String _address = '';

  void _submit() async {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();
      try {
        final newSupplier = await widget.api.addSupplier({
          'name': _name,
          'phone': _phone,
          'email': _email,
          'address': _address,
        });
        Navigator.of(context).pop(newSupplier);
      } catch (e) {
        // Handle error
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة مورد جديد'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextFormField(
                decoration: const InputDecoration(labelText: 'اسم المورد'),
                validator: (value) =>
                    value!.isEmpty ? 'الرجاء إدخال الاسم' : null,
                onSaved: (value) => _name = value!,
              ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'رقم الهاتف'),
                onSaved: (value) => _phone = value!,
              ),
              TextFormField(
                decoration: const InputDecoration(
                  labelText: 'البريد الإلكتروني',
                ),
                onSaved: (value) => _email = value!,
              ),
              TextFormField(
                decoration: const InputDecoration(labelText: 'العنوان'),
                onSaved: (value) => _address = value!,
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('إلغاء'),
          onPressed: () {
            Navigator.of(context).pop();
          },
        ),
        ElevatedButton(child: const Text('إضافة'), onPressed: _submit),
      ],
    );
  }
}
