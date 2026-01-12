import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:typed_data';

/// نظام تخطيط العناصر على القوالب الجاهزة
///
/// يسمح بـ:
/// - سحب وإفلات العناصر
/// - ضبط الموقع بالإحداثيات (X, Y)
/// - تغيير حجم العناصر
/// - معاينة على خلفية القالب
/// - حفظ التخطيط

class TemplatePositioningScreen extends StatefulWidget {
  final bool isArabic;
  final String? presetKey;
  final String? presetTitleAr;
  final String? presetTitleEn;
  final double? pageWidthPoints;
  final double? pageHeightPoints;

  const TemplatePositioningScreen({
    super.key,
    this.isArabic = true,
    this.presetKey,
    this.presetTitleAr,
    this.presetTitleEn,
    this.pageWidthPoints,
    this.pageHeightPoints,
  });

  @override
  State<TemplatePositioningScreen> createState() =>
      _TemplatePositioningScreenState();
}

class _TemplatePositioningScreenState extends State<TemplatePositioningScreen> {
  // عناصر الفاتورة القابلة للتخطيط
  final Map<String, ElementPosition> _elements = {};

  Uint8List? _backgroundImageBytes;
  bool _includeBackgroundInPrint = true;

  String? _selectedElement;
  double _zoom = 1.0;
  bool _showGrid = true;
  bool _snapToGrid = true;
  final int _gridSize = 10;

  // أبعاد الصفحة (A4 بالبيكسل عند 72 DPI)
  late final double _pageWidth;
  late final double _pageHeight;

  static const double _referencePageWidth = 595.0;
  static const double _referencePageHeight = 842.0;

  String get _storageKey {
    final suffix = (widget.presetKey ?? 'default').trim();
    return 'template_positioning_${suffix.isEmpty ? 'default' : suffix}';
  }

  String get _backgroundStorageKey {
    final suffix = (widget.presetKey ?? 'default').trim();
    return 'template_background_${suffix.isEmpty ? 'default' : suffix}';
  }

  String get _backgroundIncludeInPrintStorageKey {
    final suffix = (widget.presetKey ?? 'default').trim();
    return 'template_background_include_in_print_${suffix.isEmpty ? 'default' : suffix}';
  }

  @override
  void initState() {
    super.initState();
    _pageWidth = (widget.pageWidthPoints ?? _referencePageWidth).clamp(
      150.0,
      2000.0,
    );
    _pageHeight = (widget.pageHeightPoints ?? _referencePageHeight).clamp(
      150.0,
      4000.0,
    );
    _initializeElements();
    _loadBackgroundImage();
    _loadIncludeBackgroundInPrint();
    _loadLayout();
  }

  Future<void> _loadIncludeBackgroundInPrint() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(_backgroundIncludeInPrintStorageKey);
      if (!mounted) return;
      setState(() {
        _includeBackgroundInPrint = v ?? true;
      });
    } catch (_) {
      // ignore
    }
  }

  Future<void> _setIncludeBackgroundInPrint(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_backgroundIncludeInPrintStorageKey, value);
    if (!mounted) return;
    setState(() {
      _includeBackgroundInPrint = value;
    });
  }

  Future<void> _loadBackgroundImage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_backgroundStorageKey);
      if (raw == null || raw.trim().isEmpty) return;
      final trimmed = raw.trim();
      final commaIndex = trimmed.indexOf(',');
      final data = (trimmed.startsWith('data:') && commaIndex != -1)
          ? trimmed.substring(commaIndex + 1)
          : trimmed;
      final bytes = base64Decode(data);
      if (!mounted) return;
      setState(() {
        _backgroundImageBytes = bytes;
      });
    } catch (_) {
      // ignore
    }
  }

  Future<void> _pickBackgroundImage() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'تعذر قراءة ملف الصورة'
                  : 'Could not read image file',
            ),
          ),
        );
        return;
      }

      // Keep the stored image reasonably small since it lives in SharedPreferences.
      const maxBytes = 2 * 1024 * 1024; // 2MB
      if (bytes.lengthInBytes > maxBytes) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'حجم الصورة كبير جداً. اختر صورة أصغر (≤ 2MB)'
                  : 'Image too large. Pick a smaller one (≤ 2MB)',
            ),
          ),
        );
        return;
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_backgroundStorageKey, base64Encode(bytes));
      if (!mounted) return;
      setState(() {
        _backgroundImageBytes = Uint8List.fromList(bytes);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? '✓ تم حفظ صورة القالب لهذا المقاس'
                : '✓ Template image saved for this preset',
          ),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? 'فشل تحميل الصورة: $e'
                : 'Failed to load image: $e',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _clearBackgroundImage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_backgroundStorageKey);
    await prefs.remove(_backgroundIncludeInPrintStorageKey);
    if (!mounted) return;
    setState(() {
      _backgroundImageBytes = null;
      _includeBackgroundInPrint = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          widget.isArabic ? 'تم حذف صورة القالب' : 'Template image cleared',
        ),
      ),
    );
  }

  void _initializeElements() {
    final scaleX = _pageWidth / _referencePageWidth;
    final scaleY = _pageHeight / _referencePageHeight;

    _elements.addAll({
      'company_name': ElementPosition(
        id: 'company_name',
        nameAr: 'اسم الشركة',
        nameEn: 'Company Name',
        x: 50 * scaleX,
        y: 50 * scaleY,
        width: 200 * scaleX,
        height: 30 * scaleY,
        fontSize: 20,
      ),
      'logo': ElementPosition(
        id: 'logo',
        nameAr: 'الشعار',
        nameEn: 'Logo',
        x: 450 * scaleX,
        y: 30 * scaleY,
        width: 100 * scaleX,
        height: 100 * scaleY,
      ),
      'invoice_number': ElementPosition(
        id: 'invoice_number',
        nameAr: 'رقم الفاتورة',
        nameEn: 'Invoice Number',
        x: 50 * scaleX,
        y: 150 * scaleY,
        width: 150 * scaleX,
        height: 25 * scaleY,
        fontSize: 14,
      ),
      'date': ElementPosition(
        id: 'date',
        nameAr: 'التاريخ',
        nameEn: 'Date',
        x: 400 * scaleX,
        y: 150 * scaleY,
        width: 150 * scaleX,
        height: 25 * scaleY,
        fontSize: 14,
      ),
      'customer_name': ElementPosition(
        id: 'customer_name',
        nameAr: 'اسم العميل',
        nameEn: 'Customer Name',
        x: 50 * scaleX,
        y: 200 * scaleY,
        width: 200 * scaleX,
        height: 25 * scaleY,
        fontSize: 12,
      ),
      'customer_phone': ElementPosition(
        id: 'customer_phone',
        nameAr: 'هاتف العميل',
        nameEn: 'Customer Phone',
        x: 300 * scaleX,
        y: 200 * scaleY,
        width: 150 * scaleX,
        height: 25 * scaleY,
        fontSize: 12,
      ),
      'items_table': ElementPosition(
        id: 'items_table',
        nameAr: 'جدول الأصناف',
        nameEn: 'Items Table',
        x: 50 * scaleX,
        y: 250 * scaleY,
        width: 500 * scaleX,
        height: 300 * scaleY,
      ),
      'subtotal': ElementPosition(
        id: 'subtotal',
        nameAr: 'المجموع الفرعي',
        nameEn: 'Subtotal',
        x: 400 * scaleX,
        y: 580 * scaleY,
        width: 150 * scaleX,
        height: 25 * scaleY,
        fontSize: 12,
      ),
      'tax': ElementPosition(
        id: 'tax',
        nameAr: 'الضريبة',
        nameEn: 'Tax',
        x: 400 * scaleX,
        y: 610 * scaleY,
        width: 150 * scaleX,
        height: 25 * scaleY,
        fontSize: 12,
      ),
      'total': ElementPosition(
        id: 'total',
        nameAr: 'الإجمالي',
        nameEn: 'Total',
        x: 400 * scaleX,
        y: 650 * scaleY,
        width: 150 * scaleX,
        height: 30 * scaleY,
        fontSize: 16,
      ),
      'notes': ElementPosition(
        id: 'notes',
        nameAr: 'الملاحظات',
        nameEn: 'Notes',
        x: 50 * scaleX,
        y: 700 * scaleY,
        width: 400 * scaleX,
        height: 60 * scaleY,
        fontSize: 10,
      ),
      'footer': ElementPosition(
        id: 'footer',
        nameAr: 'التذييل',
        nameEn: 'Footer',
        x: 50 * scaleX,
        y: 780 * scaleY,
        width: 500 * scaleX,
        height: 30 * scaleY,
        fontSize: 10,
      ),
      'qr_code': ElementPosition(
        id: 'qr_code',
        nameAr: 'رمز QR',
        nameEn: 'QR Code',
        x: 50 * scaleX,
        y: 600 * scaleY,
        width: 100 * scaleX,
        height: 100 * scaleY,
      ),
      'barcode': ElementPosition(
        id: 'barcode',
        nameAr: 'الباركود',
        nameEn: 'Barcode',
        x: 200 * scaleX,
        y: 700 * scaleY,
        width: 150 * scaleX,
        height: 50 * scaleY,
      ),
    });
  }

  Future<void> _loadLayout() async {
    final prefs = await SharedPreferences.getInstance();
    final layoutJson = prefs.getString(_storageKey);
    if (layoutJson != null) {
      final layout = json.decode(layoutJson) as Map<String, dynamic>;
      setState(() {
        layout.forEach((key, value) {
          if (_elements.containsKey(key)) {
            _elements[key] = ElementPosition.fromJson(value);
          }
        });
      });
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              widget.isArabic
                  ? 'تم تحميل توزيع افتراضي للمقاس المحدد'
                  : 'Loaded default distribution for selected size',
            ),
          ),
        );
      }
    }
  }

  Future<void> _saveLayout() async {
    final layout = <String, dynamic>{};
    _elements.forEach((key, element) {
      layout[key] = element.toJson();
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_storageKey, json.encode(layout));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? '✓ تم حفظ التخطيط بنجاح'
                : '✓ Layout saved successfully',
          ),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: widget.isArabic ? TextDirection.rtl : TextDirection.ltr,
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            widget.isArabic
                ? 'ضبط موقع العناصر${(widget.presetTitleAr != null && widget.presetTitleAr!.trim().isNotEmpty) ? ' - ${widget.presetTitleAr}' : ''}'
                : 'Element Positioning${(widget.presetTitleEn != null && widget.presetTitleEn!.trim().isNotEmpty) ? ' - ${widget.presetTitleEn}' : ''}',
          ),
          backgroundColor: const Color(0xFFD4AF37),
          actions: [
            IconButton(
              icon: const Icon(Icons.image_outlined),
              tooltip: widget.isArabic
                  ? 'تحميل صورة قالب جاهز'
                  : 'Upload template background image',
              onPressed: _pickBackgroundImage,
            ),
            if (_backgroundImageBytes != null)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: widget.isArabic
                    ? 'حذف صورة القالب'
                    : 'Remove template image',
                onPressed: _clearBackgroundImage,
              ),
            IconButton(
              icon: const Icon(Icons.grid_on),
              tooltip: widget.isArabic ? 'إظهار/إخفاء الشبكة' : 'Toggle Grid',
              onPressed: () => setState(() => _showGrid = !_showGrid),
            ),
            IconButton(
              icon: Icon(_snapToGrid ? Icons.grid_3x3 : Icons.grid_off),
              tooltip: widget.isArabic ? 'الالتصاق بالشبكة' : 'Snap to Grid',
              onPressed: () => setState(() => _snapToGrid = !_snapToGrid),
            ),
            IconButton(
              icon: const Icon(Icons.zoom_in),
              onPressed: () =>
                  setState(() => _zoom = (_zoom + 0.1).clamp(0.5, 2.0)),
            ),
            IconButton(
              icon: const Icon(Icons.zoom_out),
              onPressed: () =>
                  setState(() => _zoom = (_zoom - 0.1).clamp(0.5, 2.0)),
            ),
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveLayout,
              tooltip: widget.isArabic ? 'حفظ التخطيط' : 'Save Layout',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _resetLayout,
              tooltip: widget.isArabic ? 'إعادة تعيين' : 'Reset',
            ),
          ],
        ),
        body: Row(
          children: [
            // قائمة العناصر
            Container(
              width: 280,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                border: Border(left: BorderSide(color: Colors.grey.shade300)),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    color: const Color(0xFFD4AF37).withValues(alpha: 0.1),
                    child: Row(
                      children: [
                        const Icon(Icons.layers, color: Color(0xFFD4AF37)),
                        const SizedBox(width: 8),
                        Text(
                          widget.isArabic ? 'العناصر' : 'Elements',
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_backgroundImageBytes != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: SwitchListTile.adaptive(
                        value: _includeBackgroundInPrint,
                        onChanged: (v) => _setIncludeBackgroundInPrint(v),
                        title: Text(
                          widget.isArabic
                              ? 'تضمين الصورة في الطباعة'
                              : 'Include image in printing',
                          style: const TextStyle(fontSize: 13),
                        ),
                        subtitle: Text(
                          widget.isArabic
                              ? 'إذا كانت الصورة قالب محاذاة فقط، عطّل هذا الخيار'
                              : 'Disable if the image is only for alignment',
                          style: const TextStyle(fontSize: 11),
                        ),
                        dense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 6,
                        ),
                      ),
                    ),
                  Expanded(
                    child: ListView(
                      children: _elements.entries.map((entry) {
                        return _buildElementListItem(entry.key, entry.value);
                      }).toList(),
                    ),
                  ),
                  if (_selectedElement != null) _buildElementProperties(),
                ],
              ),
            ),

            // منطقة التخطيط
            Expanded(
              child: Container(
                color: Colors.grey.shade300,
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 2.0,
                  child: Center(
                    child: Transform.scale(scale: _zoom, child: _buildCanvas()),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildElementListItem(String id, ElementPosition element) {
    final isSelected = _selectedElement == id;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: isSelected ? const Color(0xFFD4AF37).withValues(alpha: 0.2) : null,
      child: ListTile(
        dense: true,
        leading: Icon(
          _getElementIcon(id),
          color: isSelected ? const Color(0xFFD4AF37) : Colors.grey,
        ),
        title: Text(
          widget.isArabic ? element.nameAr : element.nameEn,
          style: TextStyle(
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        subtitle: Text(
          'X: ${element.x.toInt()}, Y: ${element.y.toInt()}',
          style: const TextStyle(fontSize: 11),
        ),
        trailing: Checkbox(
          value: element.visible,
          onChanged: (value) {
            setState(() {
              element.visible = value ?? true;
            });
          },
        ),
        onTap: () {
          setState(() {
            _selectedElement = isSelected ? null : id;
          });
        },
      ),
    );
  }

  Widget _buildElementProperties() {
    final element = _elements[_selectedElement]!;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.isArabic ? 'خصائص العنصر' : 'Element Properties',
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),

          Row(
            children: [
              Expanded(
                child: _buildPropertyField(
                  'X',
                  element.x,
                  (value) => setState(() => element.x = value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildPropertyField(
                  'Y',
                  element.y,
                  (value) => setState(() => element.y = value),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: _buildPropertyField(
                  widget.isArabic ? 'العرض' : 'Width',
                  element.width,
                  (value) => setState(() => element.width = value),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _buildPropertyField(
                  widget.isArabic ? 'الارتفاع' : 'Height',
                  element.height,
                  (value) => setState(() => element.height = value),
                ),
              ),
            ],
          ),

          if (element.fontSize != null) ...[
            const SizedBox(height: 8),
            _buildPropertyField(
              widget.isArabic ? 'حجم الخط' : 'Font Size',
              element.fontSize!,
              (value) => setState(() => element.fontSize = value),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPropertyField(
    String label,
    double value,
    Function(double) onChanged,
  ) {
    return TextField(
      controller: TextEditingController(text: value.toStringAsFixed(0)),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      ),
      keyboardType: TextInputType.number,
      onChanged: (text) {
        final newValue = double.tryParse(text);
        if (newValue != null) {
          onChanged(newValue);
        }
      },
    );
  }

  Widget _buildCanvas() {
    return Container(
      width: _pageWidth,
      height: _pageHeight,
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (_backgroundImageBytes != null)
            Positioned.fill(
              child: IgnorePointer(
                child: Image.memory(_backgroundImageBytes!, fit: BoxFit.fill),
              ),
            ),
          // الشبكة
          if (_showGrid) _buildGrid(),

          // العناصر
          ..._elements.entries.where((e) => e.value.visible).map((entry) {
            return _buildDraggableElement(entry.key, entry.value);
          }),
        ],
      ),
    );
  }

  Widget _buildGrid() {
    return CustomPaint(
      size: Size(_pageWidth, _pageHeight),
      painter: GridPainter(gridSize: _gridSize.toDouble()),
    );
  }

  Widget _buildDraggableElement(String id, ElementPosition element) {
    final isSelected = _selectedElement == id;

    return Positioned(
      left: element.x,
      top: element.y,
      child: GestureDetector(
        onPanUpdate: (details) {
          setState(() {
            double newX = element.x + details.delta.dx;
            double newY = element.y + details.delta.dy;

            if (_snapToGrid) {
              newX = (newX / _gridSize).round() * _gridSize.toDouble();
              newY = (newY / _gridSize).round() * _gridSize.toDouble();
            }

            element.x = newX.clamp(0, _pageWidth - element.width);
            element.y = newY.clamp(0, _pageHeight - element.height);
            _selectedElement = id;
          });
        },
        child: Container(
          width: element.width,
          height: element.height,
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? const Color(0xFFD4AF37)
                  : Colors.blue.withValues(alpha: 0.5),
              width: isSelected ? 2 : 1,
            ),
            color: isSelected
                ? const Color(0xFFD4AF37).withValues(alpha: 0.1)
                : Colors.blue.withValues(alpha: 0.05),
          ),
          child: Stack(
            children: [
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getElementIcon(id),
                      size: 20,
                      color: Colors.grey.shade600,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.isArabic ? element.nameAr : element.nameEn,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade700,
                      ),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),

              // مقابض تغيير الحجم
              if (isSelected) ...[
                _buildResizeHandle(Alignment.bottomRight, (details) {
                  setState(() {
                    element.width = (element.width + details.delta.dx).clamp(
                      50,
                      500,
                    );
                    element.height = (element.height + details.delta.dy).clamp(
                      20,
                      400,
                    );
                  });
                }),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResizeHandle(
    Alignment alignment,
    Function(DragUpdateDetails) onDrag,
  ) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        onPanUpdate: onDrag,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: const Color(0xFFD4AF37),
            border: Border.all(color: Colors.white, width: 1),
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }

  IconData _getElementIcon(String id) {
    switch (id) {
      case 'logo':
        return Icons.image;
      case 'company_name':
        return Icons.business;
      case 'invoice_number':
        return Icons.tag;
      case 'date':
        return Icons.calendar_today;
      case 'customer_name':
      case 'customer_phone':
        return Icons.person;
      case 'items_table':
        return Icons.table_chart;
      case 'subtotal':
      case 'tax':
      case 'total':
        return Icons.calculate;
      case 'notes':
        return Icons.notes;
      case 'footer':
        return Icons.view_agenda;
      case 'qr_code':
        return Icons.qr_code;
      case 'barcode':
        return Icons.barcode_reader;
      default:
        return Icons.crop_square;
    }
  }

  void _resetLayout() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'إعادة تعيين' : 'Reset Layout'),
        content: Text(
          widget.isArabic
              ? 'هل تريد إعادة تعيين جميع العناصر لمواقعها الافتراضية؟'
              : 'Do you want to reset all elements to their default positions?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _initializeElements();
              });
              Navigator.pop(context);
            },
            child: Text(widget.isArabic ? 'إعادة تعيين' : 'Reset'),
          ),
        ],
      ),
    );
  }
}

// فئة موضع العنصر
class ElementPosition {
  String id;
  String nameAr;
  String nameEn;
  double x;
  double y;
  double width;
  double height;
  double? fontSize;
  bool visible;

  ElementPosition({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.fontSize,
    this.visible = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'nameAr': nameAr,
      'nameEn': nameEn,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'fontSize': fontSize,
      'visible': visible,
    };
  }

  factory ElementPosition.fromJson(Map<String, dynamic> json) {
    return ElementPosition(
      id: json['id'],
      nameAr: json['nameAr'],
      nameEn: json['nameEn'],
      x: json['x'].toDouble(),
      y: json['y'].toDouble(),
      width: json['width'].toDouble(),
      height: json['height'].toDouble(),
      fontSize: json['fontSize']?.toDouble(),
      visible: json['visible'] ?? true,
    );
  }
}

// رسام الشبكة
class GridPainter extends CustomPainter {
  final double gridSize;

  GridPainter({required this.gridSize});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.grey.shade300
      ..strokeWidth = 0.5;

    // خطوط عمودية
    for (double x = 0; x < size.width; x += gridSize) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // خطوط أفقية
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(GridPainter oldDelegate) => false;
}
