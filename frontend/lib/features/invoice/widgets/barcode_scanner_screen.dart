import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// شاشة مسح الباركود/QR Code
class BarcodeScannerScreen extends StatefulWidget {
  const BarcodeScannerScreen({super.key});

  @override
  State<BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<BarcodeScannerScreen> {
  final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.noDuplicates,
    facing: CameraFacing.back,
  );

  bool _isProcessing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _handleBarcode(BarcodeCapture capture) {
    if (_isProcessing) return;

    final List<Barcode> barcodes = capture.barcodes;
    if (barcodes.isEmpty) return;

    final barcode = barcodes.first;
    final String? code = barcode.rawValue;

    if (code != null && code.isNotEmpty) {
      setState(() {
        _isProcessing = true;
      });

      // تشغيل اهتزاز خفيف للتأكيد
      // HapticFeedback.mediumImpact();

      // إرجاع الباركود والإغلاق
      Navigator.of(context).pop(code);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'مسح الباركود',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black.withValues(alpha: 0.7),
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        actions: [
          IconButton(
            icon: ValueListenableBuilder(
              valueListenable: _controller,
              builder: (context, value, child) {
                if (value.torchState == TorchState.unavailable) {
                  return const Icon(Icons.flash_off, color: Colors.grey);
                }
                return Icon(
                  value.torchState == TorchState.on
                      ? Icons.flash_on
                      : Icons.flash_off,
                  color: Colors.white,
                );
              },
            ),
            onPressed: () => _controller.toggleTorch(),
            tooltip: 'تشغيل/إطفاء الفلاش',
          ),
          IconButton(
            icon: const Icon(Icons.flip_camera_android, color: Colors.white),
            onPressed: () => _controller.switchCamera(),
            tooltip: 'تبديل الكاميرا',
          ),
        ],
      ),
      body: Stack(
        children: [
          // Scanner View
          MobileScanner(
            controller: _controller,
            onDetect: _handleBarcode,
            errorBuilder: (context, error, child) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.error_outline,
                      color: theme.colorScheme.error,
                      size: 48,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'خطأ في تشغيل الكاميرا',
                      style: theme.textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      error.errorDetails?.message ?? 'حدث خطأ غير معروف',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: Colors.white70,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 24),
                    ElevatedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('رجوع'),
                    ),
                  ],
                ),
              );
            },
          ),

          // Overlay Frame
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: theme.colorScheme.primary, width: 3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Stack(
                children: [
                  // Corner decorations
                  Positioned(
                    top: 0,
                    left: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                          left: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    top: 0,
                    right: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                          right: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                          left: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      width: 30,
                      height: 30,
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                          right: BorderSide(
                            color: theme.colorScheme.primary,
                            width: 5,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Instructions
          Positioned(
            bottom: 80,
            left: 0,
            right: 0,
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 32),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Text(
                    'وجّه الكاميرا نحو الباركود',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),

          // Manual Input Button
          Positioned(
            bottom: 20,
            left: 0,
            right: 0,
            child: Center(
              child: ElevatedButton.icon(
                onPressed: () async {
                  final result = await showDialog<String>(
                    context: context,
                    builder: (context) => _ManualBarcodeInputDialog(),
                  );
                  if (result != null && mounted) {
                    Navigator.of(context).pop(result);
                  }
                },
                icon: const Icon(Icons.keyboard),
                label: const Text('إدخال يدوي'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog لإدخال الباركود يدوياً
class _ManualBarcodeInputDialog extends StatefulWidget {
  @override
  State<_ManualBarcodeInputDialog> createState() =>
      _ManualBarcodeInputDialogState();
}

class _ManualBarcodeInputDialogState extends State<_ManualBarcodeInputDialog> {
  final _controller = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إدخال الباركود يدوياً'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          decoration: const InputDecoration(
            labelText: 'الباركود',
            hintText: 'أدخل رمز الباركود',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.qr_code),
          ),
          keyboardType: TextInputType.text,
          textInputAction: TextInputAction.done,
          validator: (value) {
            if (value == null || value.trim().isEmpty) {
              return 'يرجى إدخال الباركود';
            }
            if (value.trim().length < 3) {
              return 'الباركود قصير جداً';
            }
            return null;
          },
          onFieldSubmitted: (_) => _submit(),
          autofocus: true,
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        ElevatedButton(onPressed: _submit, child: const Text('تأكيد')),
      ],
    );
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_controller.text.trim());
    }
  }
}
