import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api_service.dart';
import '../providers/auth_provider.dart';
import '../theme/app_theme.dart';

class InitialSetupScreen extends StatefulWidget {
  const InitialSetupScreen({super.key});

  @override
  State<InitialSetupScreen> createState() => _InitialSetupScreenState();
}

class _InitialSetupScreenState extends State<InitialSetupScreen> {
  final _dbFormKey = GlobalKey<FormState>();
  final _storeFormKey = GlobalKey<FormState>();
  final _adminFormKey = GlobalKey<FormState>();

  int _step = 0;
  bool _busy = false;
  bool _setupLocked = false;

  // Step 1: DB config
  final _dbHostController = TextEditingController(text: 'db');
  final _dbPortController = TextEditingController(text: '5432');
  final _dbNameController = TextEditingController(text: 'yasargold');
  final _dbUserController = TextEditingController(text: 'yasargold');
  final _dbPasswordController = TextEditingController(text: 'change_me');
  bool _dbTestOk = false;

  // Step 2: Store settings
  final _companyNameController = TextEditingController(text: 'مجوهرات خالد');
  final _currencySymbolController = TextEditingController(text: 'ر.س');
  final _taxNumberController = TextEditingController();
  String? _logoDataUrl;
  bool _storeSaved = false;

  // Step 3: Admin
  final _adminUsernameController = TextEditingController(text: 'admin');
  final _fullNameController = TextEditingController(text: 'مدير النظام');
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _loadSetupLock();
  }

  Future<void> _loadSetupLock() async {
    try {
      final api = ApiService();
      final status = await api.checkSetup();
      final locked = status['setup_locked'] == true;
      if (!mounted) return;
      if (locked) {
        setState(() {
          _setupLocked = true;
          // When locked, DB/env steps are not applicable. Jump to admin creation.
          _dbTestOk = true;
          _storeSaved = true;
          _step = 2;
        });
      }
    } catch (_) {
      // Ignore; wizard can still proceed in normal mode.
    }
  }

  @override
  void dispose() {
    _dbHostController.dispose();
    _dbPortController.dispose();
    _dbNameController.dispose();
    _dbUserController.dispose();
    _dbPasswordController.dispose();

    _companyNameController.dispose();
    _currencySymbolController.dispose();
    _taxNumberController.dispose();
    _adminUsernameController.dispose();
    _fullNameController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _snack(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Colors.red : Colors.green,
      ),
    );
  }

  Future<void> _testDb() async {
    if (!_dbFormKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _dbTestOk = false;
    });

    try {
      final api = ApiService();
      final token = await api.getStoredToken();
      await api.testDatabaseConnection(
        token: token,
        host: _dbHostController.text.trim(),
        port: int.parse(_dbPortController.text.trim()),
        dbName: _dbNameController.text.trim(),
        username: _dbUserController.text.trim(),
        password: _dbPasswordController.text,
      );
      if (!mounted) return;
      setState(() => _dbTestOk = true);
      _snack('تم الاتصال بقاعدة البيانات بنجاح');
    } catch (e) {
      if (!mounted) return;
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickLogo() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      _snack('فشل قراءة ملف الشعار', error: true);
      return;
    }

    final ext = (file.extension ?? '').toLowerCase();
    final mime = ext == 'jpg' || ext == 'jpeg'
        ? 'image/jpeg'
        : ext == 'png'
            ? 'image/png'
            : 'application/octet-stream';
    final base64 = base64Encode(bytes);
    setState(() {
      _logoDataUrl = 'data:$mime;base64,$base64';
      _storeSaved = false;
    });
  }

  Future<void> _saveStore() async {
    if (!_storeFormKey.currentState!.validate()) return;

    setState(() {
      _busy = true;
      _storeSaved = false;
    });

    try {
      final api = ApiService();
      final token = await api.getStoredToken();
      await api.saveStoreSettings(
        token: token,
        companyName: _companyNameController.text.trim(),
        currencySymbol: _currencySymbolController.text.trim(),
        companyTaxNumber: _taxNumberController.text.trim(),
        companyLogoBase64: _logoDataUrl,
      );
      if (!mounted) return;
      setState(() => _storeSaved = true);
      _snack('تم حفظ إعدادات المتجر');
    } catch (e) {
      if (!mounted) return;
      _snack(e.toString().replaceFirst('Exception: ', ''), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finishSetup() async {
    if (!_adminFormKey.currentState!.validate()) return;
    if (!_setupLocked && !_dbTestOk) {
      _snack('الرجاء اختبار اتصال قاعدة البيانات أولاً', error: true);
      return;
    }
    if (!_setupLocked && !_storeSaved) {
      _snack('الرجاء حفظ إعدادات المتجر أولاً', error: true);
      return;
    }

    setState(() => _busy = true);

    final auth = context.read<AuthProvider>();
    final ok = await auth.completeInitialSetup(
      adminUsername: _adminUsernameController.text.trim(),
      keepNeedsSetup: true,
      companyName: _companyNameController.text.trim(),
      adminFullName: _fullNameController.text.trim(),
      adminPassword: _passwordController.text,
    );

    if (!mounted) return;
    if (!ok) {
      setState(() => _busy = false);
      _snack('فشل إنشاء حساب المسؤول. تأكد من البيانات وحاول مرة أخرى.',
          error: true);
      return;
    }

    try {
      if (_setupLocked) {
        // Env is already provisioned (.env.production exists). Only recreate admin, then exit setup.
        if (mounted) {
          context.read<AuthProvider>().markSetupCompleted();
        }
        _snack('تم إنشاء حساب المدير بنجاح');
        return;
      }

      final api = ApiService();
      // AuthProvider already persisted token; reuse it.
      final prefsToken = await api.getStoredToken();
      if (prefsToken == null || prefsToken.isEmpty) {
        throw Exception('فشل الحصول على توكن الجلسة');
      }

      final result = await api.writeEnvProduction(
        token: prefsToken,
        host: _dbHostController.text.trim(),
        port: int.parse(_dbPortController.text.trim()),
        dbName: _dbNameController.text.trim(),
        username: _dbUserController.text.trim(),
        password: _dbPasswordController.text,
  		restartContainers: true,
      );

      // Now that env is written, allow the app to exit setup mode.
      if (mounted) {
        context.read<AuthProvider>().markSetupCompleted();
      }

      final manual = result['manual_restart_command']?.toString();
      _snack('تمت التهيئة بنجاح. قد يلزم إعادة تشغيل الخدمات.');
      if (manual != null && manual.isNotEmpty) {
        // Show a slightly longer hint for operators
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('لإعادة التشغيل: $manual'),
            duration: const Duration(seconds: 8),
          ),
        );
      }
    } catch (e) {
      _snack(
        'تم إنشاء المسؤول، لكن فشل إنشاء ملف .env.production: ${e.toString().replaceFirst('Exception: ', '')}',
        error: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final providerLoading = context.watch<AuthProvider>().isLoading;
    final isLoading = _busy || providerLoading;

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [colorScheme.primary, colorScheme.primaryContainer],
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Card(
              elevation: 8,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(24),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.diamond,
                        size: 72,
                        color: AppColors.primaryGold,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'معالج تهيئة النظام',
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: colorScheme.primary,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(
                        value: (_step + 1) / 3,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(99),
                      ),
                      const SizedBox(height: 18),
                      Stepper(
                        currentStep: _step,
                        type: StepperType.vertical,
                        onStepContinue: isLoading
                            ? null
                            : () async {
                                if (_step == 0) {
                                  if (_dbFormKey.currentState!.validate() &&
                                      _dbTestOk) {
                                    setState(() => _step = 1);
                                  } else {
                                    _snack(
                                      'أكمل بيانات قاعدة البيانات ثم اضغط اختبار الاتصال',
                                      error: true,
                                    );
                                  }
                                  return;
                                }
                                if (_step == 1) {
                                  if (_storeSaved) {
                                    setState(() => _step = 2);
                                  } else {
                                    _snack('احفظ إعدادات المتجر أولاً', error: true);
                                  }
                                  return;
                                }
                                await _finishSetup();
                              },
                        onStepCancel: isLoading
                            ? null
                            : () {
                                if (_setupLocked) return;
                                if (_step > 0) setState(() => _step -= 1);
                              },
                        controlsBuilder: (context, details) {
                          final isLast = _step == 2;
                          return Row(
                            children: [
                              Expanded(
                                child: FilledButton(
                                  onPressed: details.onStepContinue,
                                  child: isLoading
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white,
                                          ),
                                        )
                                      : Text(isLast ? 'إنهاء التهيئة' : 'التالي'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              if (_step > 0)
                                Expanded(
                                  child: OutlinedButton(
                                    onPressed: details.onStepCancel,
                                    child: const Text('السابق'),
                                  ),
                                ),
                            ],
                          );
                        },
                        steps: [
                          Step(
                            title: const Text('اتصال قاعدة البيانات'),
                            subtitle: Text(_setupLocked ? 'غير مطلوب' : (_dbTestOk ? 'تم التحقق' : 'مطلوب')),
                            isActive: _step >= 0,
                            content: Form(
                              key: _dbFormKey,
                              child: Column(
                                children: [
                                  TextFormField(
                                    controller: _dbHostController,
                                    decoration: const InputDecoration(
                                      labelText: 'اسم السيرفر (Host)',
                                      prefixIcon: Icon(Icons.dns_outlined),
                                    ),
                                    onChanged: (_) => setState(() => _dbTestOk = false),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _dbPortController,
                                    keyboardType: TextInputType.number,
                                    decoration: const InputDecoration(
                                      labelText: 'المنفذ (Port)',
                                      prefixIcon: Icon(Icons.numbers_outlined),
                                    ),
                                    onChanged: (_) => setState(() => _dbTestOk = false),
                                    validator: (v) {
                                      final raw = (v ?? '').trim();
                                      final p = int.tryParse(raw);
                                      if (p == null || p <= 0 || p > 65535) {
                                        return 'منفذ غير صحيح';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _dbNameController,
                                    decoration: const InputDecoration(
                                      labelText: 'اسم قاعدة البيانات',
                                      prefixIcon: Icon(Icons.storage_outlined),
                                    ),
                                    onChanged: (_) => setState(() => _dbTestOk = false),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _dbUserController,
                                    decoration: const InputDecoration(
                                      labelText: 'اسم المستخدم',
                                      prefixIcon: Icon(Icons.person_outline),
                                    ),
                                    onChanged: (_) => setState(() => _dbTestOk = false),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _dbPasswordController,
                                    obscureText: true,
                                    decoration: const InputDecoration(
                                      labelText: 'كلمة المرور',
                                      prefixIcon: Icon(Icons.lock_outline),
                                    ),
                                    onChanged: (_) => setState(() => _dbTestOk = false),
                                    validator: (v) =>
                                        (v == null || v.isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 14),
                                  SizedBox(
                                    width: double.infinity,
                                    child: OutlinedButton.icon(
                                      onPressed: (_setupLocked || isLoading) ? null : _testDb,
                                      icon: const Icon(Icons.check_circle_outline),
                                      label: const Text('اختبار الاتصال'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Step(
                            title: const Text('إعدادات المتجر'),
                            subtitle: Text(_setupLocked ? 'غير مطلوب' : (_storeSaved ? 'تم الحفظ' : 'مطلوب')),
                            isActive: _step >= 1,
                            content: Form(
                              key: _storeFormKey,
                              child: Column(
                                children: [
                                  TextFormField(
                                    controller: _companyNameController,
                                    decoration: const InputDecoration(
                                      labelText: 'اسم المحل',
                                      prefixIcon: Icon(Icons.storefront_outlined),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _currencySymbolController,
                                    decoration: const InputDecoration(
                                      labelText: 'العملة الافتراضية',
                                      prefixIcon: Icon(Icons.attach_money_outlined),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _taxNumberController,
                                    decoration: const InputDecoration(
                                      labelText: 'الرقم الضريبي',
                                      prefixIcon: Icon(Icons.receipt_long_outlined),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: OutlinedButton.icon(
                                          onPressed: isLoading ? null : _pickLogo,
                                          icon: const Icon(Icons.upload_file_outlined),
                                          label: const Text('رفع شعار'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      if (_logoDataUrl != null)
                                        SizedBox(
                                          width: 48,
                                          height: 48,
                                          child: ClipRRect(
                                            borderRadius: BorderRadius.circular(8),
                                            child: Image.memory(
                                              base64Decode(
                                                _logoDataUrl!.split(',').last,
                                              ),
                                              fit: BoxFit.cover,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton.icon(
                                      onPressed: (_setupLocked || isLoading) ? null : _saveStore,
                                      icon: const Icon(Icons.save_outlined),
                                      label: const Text('حفظ إعدادات المتجر'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Step(
                            title: const Text('إنشاء حساب المدير'),
                            isActive: _step >= 2,
                            content: Form(
                              key: _adminFormKey,
                              child: Column(
                                children: [
                                  TextFormField(
                                    controller: _adminUsernameController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'البريد الإلكتروني / اسم المستخدم',
                                      prefixIcon: Icon(Icons.alternate_email),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _fullNameController,
                                    textInputAction: TextInputAction.next,
                                    decoration: const InputDecoration(
                                      labelText: 'اسم المدير',
                                      prefixIcon: Icon(Icons.person_outline),
                                    ),
                                    validator: (v) =>
                                        (v == null || v.trim().isEmpty) ? 'مطلوب' : null,
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _passwordController,
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.next,
                                    decoration: InputDecoration(
                                      labelText: 'كلمة المرور',
                                      prefixIcon: const Icon(Icons.lock_outline),
                                      suffixIcon: IconButton(
                                        icon: Icon(
                                          _obscurePassword
                                              ? Icons.visibility_off
                                              : Icons.visibility,
                                        ),
                                        onPressed: () => setState(
                                          () => _obscurePassword = !_obscurePassword,
                                        ),
                                      ),
                                    ),
                                    validator: (value) {
                                      if (value == null || value.isEmpty) {
                                        return 'كلمة المرور مطلوبة';
                                      }
                                      if (value.length < 6) {
                                        return 'كلمة المرور يجب أن تكون 6 أحرف على الأقل';
                                      }
                                      return null;
                                    },
                                  ),
                                  const SizedBox(height: 12),
                                  TextFormField(
                                    controller: _confirmPasswordController,
                                    obscureText: _obscurePassword,
                                    textInputAction: TextInputAction.done,
                                    onFieldSubmitted: (_) => _finishSetup(),
                                    decoration: const InputDecoration(
                                      labelText: 'تأكيد كلمة المرور',
                                      prefixIcon: Icon(Icons.lock_outline),
                                    ),
                                    validator: (value) {
                                      if (value == null || value.isEmpty) {
                                        return 'تأكيد كلمة المرور مطلوب';
                                      }
                                      if (value != _passwordController.text) {
                                        return 'كلمتا المرور غير متطابقتين';
                                      }
                                      return null;
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
