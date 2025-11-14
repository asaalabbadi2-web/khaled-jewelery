import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';

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

  const TemplatePositioningScreen({
    super.key,
    this.isArabic = true,
  });

  @override
  State<TemplatePositioningScreen> createState() =>
      _TemplatePositioningScreenState();
}

class _TemplatePositioningScreenState extends State<TemplatePositioningScreen> {
  // عناصر الفاتورة القابلة للتخطيط
  final Map<String, ElementPosition> _elements = {};
  
  String? _selectedElement;
  double _zoom = 1.0;
  bool _showGrid = true;
  bool _snapToGrid = true;
  int _gridSize = 10;
  
  // أبعاد الصفحة (A4 بالبيكسل عند 72 DPI)
  final double _pageWidth = 595.0;
  final double _pageHeight = 842.0;

  @override
  void initState() {
    super.initState();
    _initializeElements();
    _loadLayout();
  }

  void _initializeElements() {
    _elements.addAll({
      'company_name': ElementPosition(
        id: 'company_name',
        nameAr: 'اسم الشركة',
        nameEn: 'Company Name',
        x: 50,
        y: 50,
        width: 200,
        height: 30,
        fontSize: 20,
      ),
      'logo': ElementPosition(
        id: 'logo',
        nameAr: 'الشعار',
        nameEn: 'Logo',
        x: 450,
        y: 30,
        width: 100,
        height: 100,
      ),
      'invoice_number': ElementPosition(
        id: 'invoice_number',
        nameAr: 'رقم الفاتورة',
        nameEn: 'Invoice Number',
        x: 50,
        y: 150,
        width: 150,
        height: 25,
        fontSize: 14,
      ),
      'date': ElementPosition(
        id: 'date',
        nameAr: 'التاريخ',
        nameEn: 'Date',
        x: 400,
        y: 150,
        width: 150,
        height: 25,
        fontSize: 14,
      ),
      'customer_name': ElementPosition(
        id: 'customer_name',
        nameAr: 'اسم العميل',
        nameEn: 'Customer Name',
        x: 50,
        y: 200,
        width: 200,
        height: 25,
        fontSize: 12,
      ),
      'customer_phone': ElementPosition(
        id: 'customer_phone',
        nameAr: 'هاتف العميل',
        nameEn: 'Customer Phone',
        x: 300,
        y: 200,
        width: 150,
        height: 25,
        fontSize: 12,
      ),
      'items_table': ElementPosition(
        id: 'items_table',
        nameAr: 'جدول الأصناف',
        nameEn: 'Items Table',
        x: 50,
        y: 250,
        width: 500,
        height: 300,
      ),
      'subtotal': ElementPosition(
        id: 'subtotal',
        nameAr: 'المجموع الفرعي',
        nameEn: 'Subtotal',
        x: 400,
        y: 580,
        width: 150,
        height: 25,
        fontSize: 12,
      ),
      'tax': ElementPosition(
        id: 'tax',
        nameAr: 'الضريبة',
        nameEn: 'Tax',
        x: 400,
        y: 610,
        width: 150,
        height: 25,
        fontSize: 12,
      ),
      'total': ElementPosition(
        id: 'total',
        nameAr: 'الإجمالي',
        nameEn: 'Total',
        x: 400,
        y: 650,
        width: 150,
        height: 30,
        fontSize: 16,
      ),
      'notes': ElementPosition(
        id: 'notes',
        nameAr: 'الملاحظات',
        nameEn: 'Notes',
        x: 50,
        y: 700,
        width: 400,
        height: 60,
        fontSize: 10,
      ),
      'footer': ElementPosition(
        id: 'footer',
        nameAr: 'التذييل',
        nameEn: 'Footer',
        x: 50,
        y: 780,
        width: 500,
        height: 30,
        fontSize: 10,
      ),
      'qr_code': ElementPosition(
        id: 'qr_code',
        nameAr: 'رمز QR',
        nameEn: 'QR Code',
        x: 50,
        y: 600,
        width: 100,
        height: 100,
      ),
      'barcode': ElementPosition(
        id: 'barcode',
        nameAr: 'الباركود',
        nameEn: 'Barcode',
        x: 200,
        y: 700,
        width: 150,
        height: 50,
      ),
    });
  }

  Future<void> _loadLayout() async {
    final prefs = await SharedPreferences.getInstance();
    final layoutJson = prefs.getString('template_positioning');
    if (layoutJson != null) {
      final layout = json.decode(layoutJson) as Map<String, dynamic>;
      setState(() {
        layout.forEach((key, value) {
          if (_elements.containsKey(key)) {
            _elements[key] = ElementPosition.fromJson(value);
          }
        });
      });
    }
  }

  Future<void> _saveLayout() async {
    final layout = <String, dynamic>{};
    _elements.forEach((key, element) {
      layout[key] = element.toJson();
    });

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('template_positioning', json.encode(layout));

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
            widget.isArabic ? 'ضبط موقع العناصر' : 'Element Positioning',
          ),
          backgroundColor: const Color(0xFFD4AF37),
          actions: [
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
              onPressed: () => setState(() => _zoom = (_zoom + 0.1).clamp(0.5, 2.0)),
            ),
            IconButton(
              icon: const Icon(Icons.zoom_out),
              onPressed: () => setState(() => _zoom = (_zoom - 0.1).clamp(0.5, 2.0)),
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
                border: Border(
                  left: BorderSide(color: Colors.grey.shade300),
                ),
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
                    child: Transform.scale(
                      scale: _zoom,
                      child: _buildCanvas(),
                    ),
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
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
            ),
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
          // الشبكة
          if (_showGrid) _buildGrid(),
          
          // العناصر
          ..._elements.entries.where((e) => e.value.visible).map((entry) {
            return _buildDraggableElement(entry.key, entry.value);
          }).toList(),
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
              color: isSelected ? const Color(0xFFD4AF37) : Colors.blue.withValues(alpha: 0.5),
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
                _buildResizeHandle(
                  Alignment.bottomRight,
                  (details) {
                    setState(() {
                      element.width = (element.width + details.delta.dx).clamp(50, 500);
                      element.height = (element.height + details.delta.dy).clamp(20, 400);
                    });
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResizeHandle(Alignment alignment, Function(DragUpdateDetails) onDrag) {
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
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        paint,
      );
    }

    // خطوط أفقية
    for (double y = 0; y < size.height; y += gridSize) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(GridPainter oldDelegate) => false;
}
