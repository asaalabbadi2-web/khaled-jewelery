import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:io' show File;
import 'dart:convert';
import 'dart:math' as math;

/// شاشة تصميم القوالب الاحترافية
///
/// الميزات:
/// - تصميم مخصص لكل نوع (فواتير، سندات، قيود، كشوفات)
/// - إضافة وتحريك العناصر بحرية
/// - تخصيص الخطوط والألوان والحدود
/// - معاينة مباشرة
/// - حفظ وتحميل القوالب
class TemplateDesignerScreen extends StatefulWidget {
  final String? initialPageSize;
  final String? initialOrientation;
  final String? initialTemplateType;

  const TemplateDesignerScreen({
    super.key,
    this.initialPageSize,
    this.initialOrientation,
    this.initialTemplateType,
  });

  @override
  State<TemplateDesignerScreen> createState() => _TemplateDesignerScreenState();
}

class _TemplateDesignerScreenState extends State<TemplateDesignerScreen> {
  // أنواع القوالب المتاحة
  final List<String> _templateTypes = [
    'فاتورة بيع',
    'فاتورة شراء',
    'سند قبض',
    'سند صرف',
    'قيد يومية',
    'كشف حساب',
    'فاتورة مرتجع',
  ];

  String _selectedTemplateType = 'فاتورة بيع';

  // عناصر التصميم
  List<TemplateElement> _elements = [];
  TemplateElement? _selectedElement;

  // إعدادات الصفحة
  double _pageWidth = 210; // A4 width in mm
  double _pageHeight = 297; // A4 height in mm
  String _pageSize = 'A4';
  String _orientation = 'portrait';
  double _marginTop = 10;
  double _marginBottom = 10;
  double _marginLeft = 10;
  double _marginRight = 10;

  // أدوات التصميم المتقدمة
  bool _snapToGrid = true;
  bool _showRulers = true;
  bool _showGuides = true;
  bool _showMargins = true;
  double _gridSpacing = 5; // mm

  // ألوان الثيم
  final Color _primaryColor = const Color(0xFFD4AF37); // ذهبي
  final Color _accentColor = const Color(0xFF2C3E50);
  final List<Map<String, String>> _dynamicFields = const [
    {'label': 'اسم العميل', 'value': '{{customer_name}}'},
    {'label': 'رقم العميل', 'value': '{{customer_number}}'},
    {'label': 'رقم الفاتورة', 'value': '{{invoice_number}}'},
    {'label': 'التاريخ', 'value': '{{invoice_date}}'},
    {'label': 'الوقت', 'value': '{{invoice_time}}'},
    {'label': 'إجمالي الذهب', 'value': '{{total_gold}}'},
    {'label': 'إجمالي الأجور', 'value': '{{total_wage}}'},
    {'label': 'إجمالي الفاتورة', 'value': '{{invoice_total}}'},
    {'label': 'ملاحظات', 'value': '{{notes}}'},
    {'label': 'اسم المستخدم', 'value': '{{user_name}}'},
  ];

  static const String _templatesStorageKey =
      'template_designer_saved_templates_v1';
  List<TemplateDocument> _savedTemplates = [];
  bool _isLoadingTemplates = false;

  @override
  void initState() {
    super.initState();

    if (widget.initialTemplateType != null &&
        widget.initialTemplateType!.trim().isNotEmpty) {
      _selectedTemplateType = widget.initialTemplateType!.trim();
    }
    if (widget.initialPageSize != null &&
        widget.initialPageSize!.trim().isNotEmpty) {
      _pageSize = widget.initialPageSize!.trim();
    }
    if (widget.initialOrientation != null &&
        widget.initialOrientation!.trim().isNotEmpty) {
      _orientation = widget.initialOrientation!.trim();
    }
    _updatePageSize(notify: false);

    _loadTemplates();
    _initializeDefaultElements();
  }

  Widget _buildLayerManager() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'إدارة الطبقات',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.grey.withValues(alpha: 0.3)),
          ),
          child: ListView.builder(
            itemCount: _elements.length,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemBuilder: (context, index) {
              final reversedIndex = _elements.length - 1 - index;
              final element = _elements[reversedIndex];
              final bool selected = _selectedElement?.id == element.id;
              return ListTile(
                dense: true,
                tileColor: selected
                    ? _primaryColor.withValues(alpha: 0.15)
                    : null,
                leading: Icon(
                  element.isVisible ? Icons.visibility : Icons.visibility_off,
                  color: element.isVisible ? _accentColor : Colors.grey,
                ),
                title: Text(element.label),
                onTap: () {
                  setState(() => _selectedElement = element);
                },
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.visibility),
                      tooltip: element.isVisible ? 'إخفاء' : 'إظهار',
                      onPressed: () => _toggleVisibility(element),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_upward),
                      tooltip: 'أعلى',
                      onPressed: () => _moveLayerUp(element),
                    ),
                    IconButton(
                      icon: const Icon(Icons.arrow_downward),
                      tooltip: 'أسفل',
                      onPressed: () => _moveLayerDown(element),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  void _toggleVisibility(TemplateElement element) {
    setState(() {
      element.isVisible = !element.isVisible;
    });
  }

  void _moveLayerUp(TemplateElement element) {
    final index = _elements.indexOf(element);
    if (index >= _elements.length - 1) return;
    setState(() {
      _elements.removeAt(index);
      _elements.insert(index + 1, element);
    });
  }

  void _moveLayerDown(TemplateElement element) {
    final index = _elements.indexOf(element);
    if (index <= 0) return;
    setState(() {
      _elements.removeAt(index);
      _elements.insert(index - 1, element);
    });
  }

  void _initializeDefaultElements() {
    _elements = [
      TemplateElement(
        id: 'logo',
        type: ElementType.image,
        x: 20,
        y: 20,
        width: 80,
        height: 80,
        label: 'الشعار',
        content: 'logo.png',
        rotation: 0,
        opacity: 1,
        isVisible: true,
      ),
      TemplateElement(
        id: 'company_name',
        type: ElementType.text,
        x: 110,
        y: 20,
        width: 180,
        height: 30,
        label: 'اسم الشركة',
        content: 'مجوهرات خالد',
        fontSize: 20,
        fontWeight: 'bold',
        alignment: 'right',
        rotation: 0,
        opacity: 1,
        isVisible: true,
      ),
      TemplateElement(
        id: 'document_title',
        type: ElementType.text,
        x: 20,
        y: 110,
        width: 170,
        height: 40,
        label: 'عنوان المستند',
        content: 'فاتورة بيع',
        fontSize: 24,
        fontWeight: 'bold',
        alignment: 'center',
        backgroundColor: _primaryColor.toARGB32(),
        rotation: 0,
        opacity: 1,
        isVisible: true,
      ),
    ];
  }

  Future<void> _loadTemplates() async {
    setState(() => _isLoadingTemplates = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getStringList(_templatesStorageKey) ?? [];
      final templates = stored
          .map((raw) {
            try {
              return TemplateDocument.fromJson(
                jsonDecode(raw) as Map<String, dynamic>,
              );
            } catch (_) {
              return null;
            }
          })
          .whereType<TemplateDocument>()
          .toList();

      if (mounted) {
        setState(() {
          _savedTemplates = templates;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('خطأ في تحميل القوالب: $e')));
      }
    } finally {
      if (mounted) {
        setState(() => _isLoadingTemplates = false);
      }
    }
  }

  Future<void> _persistTemplates() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = _savedTemplates
        .map((template) => jsonEncode(template.toJson()))
        .toList();
    await prefs.setStringList(_templatesStorageKey, encoded);
  }

  TemplateDocument _buildCurrentTemplate(String name, {String? createdAt}) {
    final now = DateTime.now().toIso8601String();
    return TemplateDocument(
      name: name,
      type: _selectedTemplateType,
      pageSize: _pageSize,
      pageWidth: _pageWidth,
      pageHeight: _pageHeight,
      orientation: _orientation,
      marginTop: _marginTop,
      marginBottom: _marginBottom,
      marginLeft: _marginLeft,
      marginRight: _marginRight,
      snapToGrid: _snapToGrid,
      showGuides: _showGuides,
      showMargins: _showMargins,
      showRulers: _showRulers,
      gridSpacing: _gridSpacing,
      elements: _elements.map((e) => e.clone()).toList(),
      createdAt: createdAt ?? now,
      updatedAt: now,
    );
  }

  void _applyTemplate(TemplateDocument template) {
    setState(() {
      _selectedTemplateType = template.type;
      _pageSize = template.pageSize;
      _pageWidth = template.pageWidth;
      _pageHeight = template.pageHeight;
      _orientation = template.orientation;
      _marginTop = template.marginTop;
      _marginBottom = template.marginBottom;
      _marginLeft = template.marginLeft;
      _marginRight = template.marginRight;
      _snapToGrid = template.snapToGrid;
      _showGuides = template.showGuides;
      _showMargins = template.showMargins;
      _showRulers = template.showRulers;
      _gridSpacing = template.gridSpacing;
      _elements = template.elements.map((element) => element.clone()).toList();
      _selectedElement = null;
    });
  }

  Future<void> _deleteTemplate(TemplateDocument template) async {
    setState(() {
      _savedTemplates.removeWhere((t) => t.name == template.name);
    });
    await _persistTemplates();
  }

  String _generateUniqueName(String base) {
    final sanitized = base.isEmpty ? 'قالب بدون اسم' : base;
    if (_savedTemplates.every((t) => t.name != sanitized)) {
      return sanitized;
    }
    int counter = 1;
    while (_savedTemplates.any((t) => t.name == '$sanitized ($counter)')) {
      counter++;
    }
    return '$sanitized ($counter)';
  }

  String _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return 'غير معروف';
    final formatted = timestamp.replaceFirst('T', ' ');
    final parts = formatted.split('.');
    return parts.isNotEmpty ? parts.first : formatted;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('مصمم القوالب'),
        backgroundColor: _primaryColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveTemplate,
            tooltip: 'حفظ القالب',
          ),
          IconButton(
            icon: const Icon(Icons.folder_open),
            onPressed: _loadTemplate,
            tooltip: 'فتح قالب',
          ),
          IconButton(
            icon: const Icon(Icons.visibility),
            onPressed: _previewTemplate,
            tooltip: 'معاينة',
          ),
          IconButton(
            icon: const Icon(Icons.file_download),
            onPressed: _exportTemplate,
            tooltip: 'تصدير القالب',
          ),
          IconButton(
            icon: const Icon(Icons.file_upload),
            onPressed: _importTemplate,
            tooltip: 'استيراد قالب',
          ),
          if (_selectedElement != null)
            IconButton(
              icon: const Icon(Icons.copy),
              onPressed: _duplicateElement,
              tooltip: 'نسخ العنصر',
            ),
          if (_elements.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _clearAll,
              tooltip: 'مسح الكل',
            ),
        ],
      ),
      body: Row(
        children: [
          // الشريط الجانبي - أدوات التصميم
          _buildToolbar(),

          // منطقة التصميم
          Expanded(flex: 3, child: _buildDesignCanvas()),

          // لوحة الخصائص
          _buildPropertiesPanel(),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      width: 280,
      color: Colors.grey[100],
      child: Column(
        children: [
          // نوع القالب
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'نوع القالب',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _selectedTemplateType,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: _templateTypes.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type, overflow: TextOverflow.ellipsis),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedTemplateType = value!;
                      _initializeDefaultElements();
                    });
                  },
                ),
              ],
            ),
          ),

          const Divider(),

          // حجم الصفحة
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'حجم الصفحة',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: _pageSize,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: 'A4',
                      child: Text(
                        'A4 (210×297 mm)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'A5',
                      child: Text(
                        'A5 (148×210 mm)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'Letter',
                      child: Text(
                        'Letter (216×279 mm)',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: 'Custom',
                      child: Text('مخصص', overflow: TextOverflow.ellipsis),
                    ),
                  ],
                  onChanged: (value) {
                    setState(() {
                      _pageSize = value!;
                      _updatePageSize();
                    });
                  },
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'portrait',
                      label: Text('عمودي'),
                      icon: Icon(Icons.stay_current_portrait),
                    ),
                    ButtonSegment(
                      value: 'landscape',
                      label: Text('أفقي'),
                      icon: Icon(Icons.stay_current_landscape),
                    ),
                  ],
                  selected: {_orientation},
                  onSelectionChanged: (selection) {
                    if (selection.isEmpty) return;
                    setState(() {
                      _orientation = selection.first;
                      _updatePageSize();
                    });
                  },
                  style: ButtonStyle(
                    padding: WidgetStateProperty.all(
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
          ),

          const Divider(),

          // إعدادات التخطيط
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'أدوات التخطيط',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                SwitchListTile.adaptive(
                  value: _snapToGrid,
                  onChanged: (value) => setState(() => _snapToGrid = value),
                  title: const Text('الالتصاق بالشبكة'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile.adaptive(
                  value: _showRulers,
                  onChanged: (value) => setState(() => _showRulers = value),
                  title: const Text('إظهار المساطر'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile.adaptive(
                  value: _showGuides,
                  onChanged: (value) => setState(() => _showGuides = value),
                  title: const Text('إظهار الأدلة (Guides)'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                SwitchListTile.adaptive(
                  value: _showMargins,
                  onChanged: (value) => setState(() => _showMargins = value),
                  title: const Text('إظهار الهوامش'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                ),
                const SizedBox(height: 8),
                Text(
                  'المسافة بين خطوط الشبكة: ${_gridSpacing.toStringAsFixed(0)} مم',
                ),
                Slider(
                  min: 2,
                  max: 20,
                  value: _gridSpacing,
                  onChanged: (value) => setState(() => _gridSpacing = value),
                ),
              ],
            ),
          ),

          const Divider(),

          // العناصر المتاحة والديناميكية
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                const Text(
                  'العناصر المتاحة',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                _buildElementButton('نص', Icons.text_fields, ElementType.text),
                _buildElementButton(
                  'صورة/شعار',
                  Icons.image,
                  ElementType.image,
                ),
                _buildElementButton(
                  'جدول',
                  Icons.table_chart,
                  ElementType.table,
                ),
                _buildElementButton(
                  'خط فاصل',
                  Icons.horizontal_rule,
                  ElementType.line,
                ),
                _buildElementButton(
                  'مستطيل',
                  Icons.rectangle_outlined,
                  ElementType.rectangle,
                ),
                _buildElementButton(
                  'باركود',
                  Icons.qr_code,
                  ElementType.barcode,
                ),
                _buildElementButton(
                  'حقل تاريخ',
                  Icons.calendar_today,
                  ElementType.dateField,
                ),
                _buildElementButton(
                  'حقل رقم',
                  Icons.numbers,
                  ElementType.numberField,
                ),
                const SizedBox(height: 16),
                const Text(
                  'الحقول الديناميكية',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _dynamicFields.map((field) {
                    return ActionChip(
                      label: Text(field['label']!),
                      onPressed: () => _insertDynamicField(field['value']!),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),
          const Divider(),

          // إدارة القوالب السريعة
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'القوالب المحفوظة',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _loadTemplate,
                        icon: const Icon(Icons.folder_open),
                        label: const Text('فتح قالب'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: _accentColor,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton.icon(
                        onPressed: _importTemplate,
                        icon: const Icon(Icons.file_upload),
                        label: const Text('استيراد ملف'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: _accentColor,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 12,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildElementButton(String label, IconData icon, ElementType type) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: ElevatedButton.icon(
        onPressed: () => _addElement(type),
        icon: Icon(icon, size: 20),
        label: Text(label),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: _accentColor,
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        ),
      ),
    );
  }

  Widget _buildDesignCanvas() {
    const double scale = 0.85;
    final double canvasWidth = _pageWidth * scale * 3.78;
    final double canvasHeight = _pageHeight * scale * 3.78;
    final double rulerSpace = _showRulers ? 28 : 0;

    return Column(
      children: [
        _buildAlignmentToolbar(),
        Expanded(
          child: Container(
            color: Colors.grey[300],
            alignment: Alignment.center,
            child: SizedBox(
              width: canvasWidth + rulerSpace,
              height: canvasHeight + rulerSpace,
              child: Stack(
                children: [
                  if (_showRulers)
                    Positioned(
                      left: rulerSpace,
                      top: 0,
                      right: 0,
                      height: rulerSpace,
                      child: CustomPaint(
                        painter: RulerPainter(
                          isHorizontal: true,
                          length: _pageWidth,
                          pxPerMm: scale * 3.78,
                        ),
                      ),
                    ),
                  if (_showRulers)
                    Positioned(
                      top: rulerSpace,
                      bottom: 0,
                      left: 0,
                      width: rulerSpace,
                      child: CustomPaint(
                        painter: RulerPainter(
                          isHorizontal: false,
                          length: _pageHeight,
                          pxPerMm: scale * 3.78,
                        ),
                      ),
                    ),
                  Positioned(
                    left: rulerSpace,
                    top: rulerSpace,
                    child: Container(
                      width: canvasWidth,
                      height: canvasHeight,
                      color: Colors.white,
                      child: Stack(
                        children: [
                          CustomPaint(
                            size: Size(canvasWidth, canvasHeight),
                            painter: GridPainter(
                              gridSpacing: _gridSpacing,
                              pxPerMm: scale * 3.78,
                              showGuides: _showGuides,
                              showMargins: _showMargins,
                              marginTop: _marginTop,
                              marginBottom: _marginBottom,
                              marginLeft: _marginLeft,
                              marginRight: _marginRight,
                            ),
                          ),
                          ..._elements.map(
                            (element) => _buildDraggableElement(element, scale),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildAlignmentToolbar() {
    return Container(
      color: Colors.grey[100],
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            _toolbarActionButton(
              Icons.format_align_left,
              'محاذاة يسار',
              () => _alignSelected('left'),
            ),
            _toolbarActionButton(
              Icons.format_align_center,
              'محاذاة وسط',
              () => _alignSelected('center-horizontal'),
            ),
            _toolbarActionButton(
              Icons.format_align_right,
              'محاذاة يمين',
              () => _alignSelected('right'),
            ),
            const VerticalDivider(width: 12),
            _toolbarActionButton(
              Icons.vertical_align_top,
              'محاذاة أعلى',
              () => _alignSelected('top'),
            ),
            _toolbarActionButton(
              Icons.vertical_align_center,
              'محاذاة وسط عمودي',
              () => _alignSelected('center-vertical'),
            ),
            _toolbarActionButton(
              Icons.vertical_align_bottom,
              'محاذاة أسفل',
              () => _alignSelected('bottom'),
            ),
            const VerticalDivider(width: 12),
            _toolbarActionButton(
              Icons.unfold_more,
              'توسيع لعرض الصفحة',
              () => _stretchSelected('width'),
            ),
            _toolbarActionButton(
              Icons.unfold_less,
              'توسيع لطول الصفحة',
              () => _stretchSelected('height'),
            ),
            const VerticalDivider(width: 12),
            _toolbarActionButton(
              Icons.flip_to_front,
              'إحضار للأمام',
              _bringToFront,
            ),
            _toolbarActionButton(
              Icons.flip_to_back,
              'إرسال للخلف',
              _sendToBack,
            ),
            _toolbarActionButton(
              Icons.visibility,
              'تبديل الإظهار',
              _toggleSelectedVisibility,
            ),
            _toolbarActionButton(
              Icons.content_copy,
              'نسخ سريع',
              _duplicateElement,
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbarActionButton(
    IconData icon,
    String tooltip,
    VoidCallback onPressed,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: Colors.grey.withValues(alpha: 0.3)),
          ),
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Icon(icon, size: 20, color: _accentColor),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDraggableElement(TemplateElement element, double scale) {
    if (!element.isVisible && !_showGuides) {
      return const SizedBox.shrink();
    }

    final isSelected = _selectedElement?.id == element.id;
    final double pxPerMm = scale * 3.78;
    final Widget elementContent = Opacity(
      opacity: (element.opacity ?? 1.0) * (element.isVisible ? 1 : 0.2),
      child: Transform.rotate(
        angle: (element.rotation ?? 0) * math.pi / 180,
        child: Container(
          width: element.width * pxPerMm,
          height: element.height * pxPerMm,
          decoration: BoxDecoration(
            border: Border.all(
              color: isSelected
                  ? _primaryColor
                  : Colors.grey.withValues(alpha: 0.4),
              width: isSelected ? 2 : 1,
              style: element.isVisible ? BorderStyle.solid : BorderStyle.solid,
            ),
            color: element.backgroundColor != null
                ? Color(
                    element.backgroundColor!,
                  ).withValues(alpha: element.isVisible ? 1 : 0.2)
                : null,
            borderRadius: element.borderRadius != null
                ? BorderRadius.circular(element.borderRadius!)
                : null,
          ),
          child: Stack(
            children: [
              _buildElementContent(element, scale),
              if (!element.isVisible)
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.7),
                      borderRadius: element.borderRadius != null
                          ? BorderRadius.circular(element.borderRadius!)
                          : null,
                    ),
                    child: const Icon(
                      Icons.visibility_off,
                      color: Colors.black54,
                    ),
                  ),
                ),
              if (isSelected) ..._buildResizeHandles(element, scale),
            ],
          ),
        ),
      ),
    );

    return Positioned(
      left: element.x * pxPerMm,
      top: element.y * pxPerMm,
      child: MouseRegion(
        cursor: SystemMouseCursors.move,
        child: GestureDetector(
          onTap: () {
            setState(() {
              _selectedElement = element;
            });
          },
          onPanUpdate: (details) {
            setState(() {
              element.x += details.delta.dx / pxPerMm;
              element.y += details.delta.dy / pxPerMm;
            });
          },
          onPanEnd: (_) {
            _handleElementDragEnd(element);
          },
          child: elementContent,
        ),
      ),
    );
  }

  List<Widget> _buildResizeHandles(TemplateElement element, double scale) {
    final double pxPerMm = scale * 3.78;
    return [
      Positioned(
        right: -6,
        bottom: -6,
        child: _resizeHandle(Icons.open_in_full, (dx, dy) {
          element.width += dx / pxPerMm;
          element.height += dy / pxPerMm;
        }, element),
      ),
      Positioned(
        right: -6,
        top: (element.height * pxPerMm) / 2 - 6,
        child: _resizeHandle(Icons.swap_horiz, (dx, dy) {
          element.width += dx / pxPerMm;
        }, element),
      ),
      Positioned(
        bottom: -6,
        left: (element.width * pxPerMm) / 2 - 6,
        child: _resizeHandle(Icons.swap_vert, (dx, dy) {
          element.height += dy / pxPerMm;
        }, element),
      ),
    ];
  }

  Widget _resizeHandle(
    IconData icon,
    void Function(double dx, double dy) onResize,
    TemplateElement element,
  ) {
    return GestureDetector(
      onPanUpdate: (details) {
        setState(() {
          onResize(details.delta.dx, details.delta.dy);
          if (element.width < 10) element.width = 10;
          if (element.height < 10) element.height = 10;
        });
      },
      onPanEnd: (_) => _handleElementDragEnd(element),
      child: Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(color: _primaryColor, shape: BoxShape.circle),
        child: Icon(icon, size: 10, color: Colors.white),
      ),
    );
  }

  void _handleElementDragEnd(TemplateElement element) {
    setState(() {
      _applySnap(element);
      _clampElementWithinPage(element);
    });
  }

  void _applySnap(TemplateElement element) {
    if (!_snapToGrid || _gridSpacing <= 0) return;
    element.x = _snapValue(element.x);
    element.y = _snapValue(element.y);
    element.width = _snapValue(element.width).clamp(5, _pageWidth);
    element.height = _snapValue(element.height).clamp(5, _pageHeight);
  }

  double _snapValue(double value) {
    if (!_snapToGrid || _gridSpacing <= 0) return value;
    final step = _gridSpacing;
    return (value / step).roundToDouble() * step;
  }

  void _clampElementWithinPage(TemplateElement element) {
    final double maxX = _pageWidth - element.width - _marginRight;
    final double maxY = _pageHeight - element.height - _marginBottom;
    element.x = element.x.clamp(
      _marginLeft,
      maxX < _marginLeft ? _marginLeft : maxX,
    );
    element.y = element.y.clamp(
      _marginTop,
      maxY < _marginTop ? _marginTop : maxY,
    );
  }

  Widget _buildElementContent(TemplateElement element, double scale) {
    switch (element.type) {
      case ElementType.text:
        return Center(
          child: Text(
            element.content ?? 'نص',
            style: TextStyle(
              fontSize: (element.fontSize ?? 14) * scale,
              fontWeight: element.fontWeight == 'bold'
                  ? FontWeight.bold
                  : FontWeight.normal,
              color: element.textColor != null
                  ? Color(element.textColor!)
                  : Colors.black,
            ),
            textAlign: _getTextAlignment(element.alignment),
          ),
        );

      case ElementType.image:
        return Center(
          child: Icon(Icons.image, size: 40 * scale, color: Colors.grey),
        );

      case ElementType.table:
        return Center(
          child: Icon(Icons.table_chart, size: 40 * scale, color: Colors.grey),
        );

      case ElementType.line:
        return Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: element.borderColor != null
                    ? Color(element.borderColor!)
                    : Colors.black,
                width: element.borderWidth ?? 1,
              ),
            ),
          ),
        );

      case ElementType.rectangle:
        return Container(
          decoration: BoxDecoration(
            border: Border.all(
              color: element.borderColor != null
                  ? Color(element.borderColor!)
                  : Colors.black,
              width: element.borderWidth ?? 1,
            ),
          ),
        );

      case ElementType.barcode:
        return Center(
          child: Icon(Icons.qr_code_2, size: 40 * scale, color: Colors.black),
        );

      case ElementType.dateField:
        return Center(
          child: Text(
            element.content ?? '2025/11/14',
            style: TextStyle(fontSize: (element.fontSize ?? 12) * scale),
          ),
        );

      case ElementType.numberField:
        return Center(
          child: Text(
            element.content ?? '0.00',
            style: TextStyle(fontSize: (element.fontSize ?? 12) * scale),
          ),
        );
    }
  }

  Widget _buildPropertiesPanel() {
    if (_selectedElement == null) {
      return Container(
        width: 280,
        color: Colors.grey[100],
        child: const Center(child: Text('اختر عنصراً لتحرير خصائصه')),
      );
    }

    final element = _selectedElement!;

    return Container(
      width: 280,
      color: Colors.grey[100],
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'خصائص ${element.label}',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete, color: Colors.red),
                onPressed: () {
                  setState(() {
                    _elements.remove(element);
                    _selectedElement = null;
                  });
                },
                tooltip: 'حذف العنصر',
              ),
            ],
          ),

          const Divider(),

          // الموضع والحجم
          const Text(
            'الموضع والحجم',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'X (mm)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                  ),
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(
                    text: element.x.toStringAsFixed(1),
                  ),
                  onChanged: (value) {
                    setState(() {
                      element.x = double.tryParse(value) ?? element.x;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Y (mm)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                  ),
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(
                    text: element.y.toStringAsFixed(1),
                  ),
                  onChanged: (value) {
                    setState(() {
                      element.y = double.tryParse(value) ?? element.y;
                    });
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'العرض (mm)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                  ),
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(
                    text: element.width.toStringAsFixed(1),
                  ),
                  onChanged: (value) {
                    setState(() {
                      element.width = double.tryParse(value) ?? element.width;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'الارتفاع (mm)',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                  ),
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(
                    text: element.height.toStringAsFixed(1),
                  ),
                  onChanged: (value) {
                    setState(() {
                      element.height = double.tryParse(value) ?? element.height;
                    });
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // خصائص النص
          if (element.type == ElementType.text ||
              element.type == ElementType.dateField ||
              element.type == ElementType.numberField) ...[
            const Text(
              'خصائص النص',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),

            TextField(
              decoration: const InputDecoration(
                labelText: 'المحتوى',
                border: OutlineInputBorder(),
              ),
              controller: TextEditingController(text: element.content),
              onChanged: (value) {
                setState(() {
                  element.content = value;
                });
              },
              maxLines: 3,
            ),

            const SizedBox(height: 8),

            TextField(
              decoration: const InputDecoration(
                labelText: 'حجم الخط',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.all(8),
              ),
              keyboardType: TextInputType.number,
              controller: TextEditingController(
                text: (element.fontSize ?? 14).toString(),
              ),
              onChanged: (value) {
                setState(() {
                  element.fontSize = double.tryParse(value) ?? 14;
                });
              },
            ),

            const SizedBox(height: 8),

            DropdownButtonFormField<String>(
              initialValue: element.fontWeight ?? 'normal',
              decoration: const InputDecoration(
                labelText: 'وزن الخط',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'normal', child: Text('عادي')),
                DropdownMenuItem(value: 'bold', child: Text('عريض')),
              ],
              onChanged: (value) {
                setState(() {
                  element.fontWeight = value;
                });
              },
            ),

            const SizedBox(height: 8),

            DropdownButtonFormField<String>(
              initialValue: element.alignment ?? 'right',
              decoration: const InputDecoration(
                labelText: 'المحاذاة',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
              ),
              items: const [
                DropdownMenuItem(value: 'right', child: Text('يمين')),
                DropdownMenuItem(value: 'center', child: Text('وسط')),
                DropdownMenuItem(value: 'left', child: Text('يسار')),
              ],
              onChanged: (value) {
                setState(() {
                  element.alignment = value;
                });
              },
            ),
          ],

          const SizedBox(height: 16),

          // الألوان
          const Text('الألوان', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),

          ListTile(
            title: const Text('لون الخلفية'),
            trailing: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: element.backgroundColor != null
                    ? Color(element.backgroundColor!)
                    : Colors.transparent,
                border: Border.all(color: Colors.grey),
              ),
            ),
            onTap: () => _pickColor(element, 'background'),
          ),

          if (element.type == ElementType.text ||
              element.type == ElementType.dateField ||
              element.type == ElementType.numberField)
            ListTile(
              title: const Text('لون النص'),
              trailing: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: element.textColor != null
                      ? Color(element.textColor!)
                      : Colors.black,
                  border: Border.all(color: Colors.grey),
                ),
              ),
              onTap: () => _pickColor(element, 'text'),
            ),

          ListTile(
            title: const Text('لون الحدود'),
            trailing: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: element.borderColor != null
                    ? Color(element.borderColor!)
                    : Colors.transparent,
                border: Border.all(color: Colors.grey),
              ),
            ),
            onTap: () => _pickColor(element, 'border'),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'سماكة الحدود',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                  ),
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(
                    text: (element.borderWidth ?? 1).toString(),
                  ),
                  onChanged: (value) {
                    setState(() {
                      element.borderWidth =
                          double.tryParse(value) ?? element.borderWidth;
                    });
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'زوايا مستديرة',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.all(8),
                  ),
                  keyboardType: TextInputType.number,
                  controller: TextEditingController(
                    text: (element.borderRadius ?? 0).toString(),
                  ),
                  onChanged: (value) {
                    setState(() {
                      element.borderRadius =
                          double.tryParse(value) ?? element.borderRadius;
                    });
                  },
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),
          const Text(
            'المظهر المتقدم',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          SwitchListTile.adaptive(
            value: element.isVisible,
            onChanged: (value) {
              setState(() {
                element.isVisible = value;
              });
            },
            title: const Text('إظهار العنصر في الطباعة'),
            contentPadding: EdgeInsets.zero,
          ),
          const SizedBox(height: 8),
          Text('الشفافية: ${((element.opacity ?? 1) * 100).round()}%'),
          Slider(
            min: 0.1,
            max: 1,
            divisions: 9,
            value: (element.opacity ?? 1).clamp(0.1, 1),
            onChanged: (value) {
              setState(() {
                element.opacity = value;
              });
            },
          ),
          const SizedBox(height: 8),
          Text('الدوران: ${element.rotation?.toStringAsFixed(0) ?? '0'}°'),
          Slider(
            min: -180,
            max: 180,
            value: (element.rotation ?? 0).clamp(-180, 180),
            onChanged: (value) {
              setState(() {
                element.rotation = value;
              });
            },
          ),

          const Divider(height: 32),
          _buildLayerManager(),
        ],
      ),
    );
  }

  void _updatePageSize({bool notify = true}) {
    if (_pageSize == 'A4') {
      if (_orientation == 'portrait') {
        _pageWidth = 210;
        _pageHeight = 297;
      } else {
        _pageWidth = 297;
        _pageHeight = 210;
      }
    } else if (_pageSize == 'A5') {
      if (_orientation == 'portrait') {
        _pageWidth = 148;
        _pageHeight = 210;
      } else {
        _pageWidth = 210;
        _pageHeight = 148;
      }
    } else if (_pageSize == 'Letter') {
      if (_orientation == 'portrait') {
        _pageWidth = 216;
        _pageHeight = 279;
      } else {
        _pageWidth = 279;
        _pageHeight = 216;
      }
    }
    if (notify) {
      setState(() {});
    }
  }

  void _insertDynamicField(String value) {
    if (_selectedElement == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('اختر عنصراً نصياً لإضافة الحقل')),
      );
      return;
    }

    if (_selectedElement!.type == ElementType.text ||
        _selectedElement!.type == ElementType.dateField ||
        _selectedElement!.type == ElementType.numberField) {
      setState(() {
        final current = _selectedElement!.content ?? '';
        _selectedElement!.content = (current.isEmpty
            ? value
            : '$current $value');
      });
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('يمكن إضافة الحقول الديناميكية للعناصر النصية فقط'),
        ),
      );
    }
  }

  void _alignSelected(String mode) {
    if (_selectedElement == null) return;
    setState(() {
      switch (mode) {
        case 'left':
          _selectedElement!.x = _marginLeft;
          break;
        case 'right':
          _selectedElement!.x =
              _pageWidth - _selectedElement!.width - _marginRight;
          break;
        case 'center-horizontal':
          _selectedElement!.x = (_pageWidth - _selectedElement!.width) / 2;
          break;
        case 'top':
          _selectedElement!.y = _marginTop;
          break;
        case 'bottom':
          _selectedElement!.y =
              _pageHeight - _selectedElement!.height - _marginBottom;
          break;
        case 'center-vertical':
          _selectedElement!.y = (_pageHeight - _selectedElement!.height) / 2;
          break;
      }
    });
  }

  void _stretchSelected(String axis) {
    if (_selectedElement == null) return;
    setState(() {
      if (axis == 'width') {
        _selectedElement!.x = _marginLeft;
        _selectedElement!.width = _pageWidth - _marginLeft - _marginRight;
      } else {
        _selectedElement!.y = _marginTop;
        _selectedElement!.height = _pageHeight - _marginTop - _marginBottom;
      }
    });
  }

  void _toggleSelectedVisibility() {
    if (_selectedElement == null) return;
    setState(() {
      _selectedElement!.isVisible = !_selectedElement!.isVisible;
    });
  }

  void _bringToFront() {
    if (_selectedElement == null) return;
    setState(() {
      _elements.remove(_selectedElement);
      _elements.add(_selectedElement!);
    });
  }

  void _sendToBack() {
    if (_selectedElement == null) return;
    setState(() {
      _elements.remove(_selectedElement);
      _elements.insert(0, _selectedElement!);
    });
  }

  void _addElement(ElementType type) {
    final newElement = TemplateElement(
      id: 'element_${DateTime.now().millisecondsSinceEpoch}',
      type: type,
      x: _marginLeft + 5,
      y: _marginTop + 5,
      width: type == ElementType.line ? 170 : 100,
      height: type == ElementType.line ? 2 : 30,
      label: _getElementTypeLabel(type),
      content: _getDefaultContent(type),
      rotation: 0,
      opacity: 1,
      isVisible: true,
      borderRadius: type == ElementType.rectangle ? 6 : 0,
    );

    setState(() {
      _elements.add(newElement);
      _selectedElement = newElement;
    });
  }

  String _getElementTypeLabel(ElementType type) {
    switch (type) {
      case ElementType.text:
        return 'نص';
      case ElementType.image:
        return 'صورة';
      case ElementType.table:
        return 'جدول';
      case ElementType.line:
        return 'خط';
      case ElementType.rectangle:
        return 'مستطيل';
      case ElementType.barcode:
        return 'باركود';
      case ElementType.dateField:
        return 'تاريخ';
      case ElementType.numberField:
        return 'رقم';
    }
  }

  String _getDefaultContent(ElementType type) {
    switch (type) {
      case ElementType.text:
        return 'نص جديد';
      case ElementType.dateField:
        return '{{date}}';
      case ElementType.numberField:
        return '{{number}}';
      default:
        return '';
    }
  }

  TextAlign _getTextAlignment(String? alignment) {
    switch (alignment) {
      case 'left':
        return TextAlign.left;
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      default:
        return TextAlign.right;
    }
  }

  void _pickColor(TemplateElement element, String colorType) async {
    final Color? pickedColor = await showDialog<Color>(
      context: context,
      builder: (context) => _ColorPickerDialog(
        currentColor: colorType == 'background'
            ? (element.backgroundColor != null
                  ? Color(element.backgroundColor!)
                  : Colors.transparent)
            : (element.textColor != null
                  ? Color(element.textColor!)
                  : Colors.black),
      ),
    );

    if (pickedColor != null && mounted) {
      setState(() {
        if (colorType == 'background') {
          element.backgroundColor = pickedColor.toARGB32();
        } else if (colorType == 'text') {
          element.textColor = pickedColor.toARGB32();
        } else if (colorType == 'border') {
          element.borderColor = pickedColor.toARGB32();
        }
      });
    }
  }

  void _saveTemplate() async {
    final TextEditingController nameController = TextEditingController();

    final templateName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حفظ القالب'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(
            labelText: 'اسم القالب',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );

    if (templateName == null || templateName.isEmpty) return;

    try {
      final existingIndex = _savedTemplates.indexWhere(
        (t) => t.name == templateName,
      );
      final existing = existingIndex >= 0
          ? _savedTemplates[existingIndex]
          : null;
      final template = _buildCurrentTemplate(
        templateName,
        createdAt: existing?.createdAt,
      );

      setState(() {
        if (existingIndex >= 0) {
          _savedTemplates[existingIndex] = template;
        } else {
          _savedTemplates.add(template);
        }
      });
      await _persistTemplates();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              existingIndex >= 0
                  ? 'تم تحديث القالب "$templateName"'
                  : 'تم حفظ القالب "$templateName" بنجاح',
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في حفظ القالب: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _loadTemplate() async {
    if (_isLoadingTemplates) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('جارٍ تحميل القوالب، يرجى الانتظار...')),
      );
      return;
    }

    if (_savedTemplates.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('لا توجد قوالب محفوظة بعد')));
      return;
    }

    final TemplateDocument? selected = await showDialog<TemplateDocument>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('القوالب المحفوظة'),
          content: SizedBox(
            width: 420,
            height: 360,
            child: _savedTemplates.isEmpty
                ? const Center(child: Text('لا توجد قوالب محفوظة'))
                : ListView.separated(
                    shrinkWrap: true,
                    itemBuilder: (context, index) {
                      final template = _savedTemplates[index];
                      return ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 4,
                          horizontal: 8,
                        ),
                        title: Text(
                          template.name,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          '${template.type} • آخر تعديل: ${_formatTimestamp(template.updatedAt ?? template.createdAt)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        onTap: () => Navigator.pop(dialogContext, template),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: const Icon(Icons.share),
                              tooltip: 'تصدير',
                              onPressed: () async {
                                final jsonString = const JsonEncoder.withIndent(
                                  '  ',
                                ).convert(template.toJson());
                                await Clipboard.setData(
                                  ClipboardData(text: jsonString),
                                );
                                try {
                                  await SharePlus.instance.share(
                                    ShareParams(
                                      text: jsonString,
                                      title: 'قالب ${template.name}',
                                    ),
                                  );
                                } catch (_) {}
                                if (mounted) {
                                  ScaffoldMessenger.of(
                                    this.context,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'تم نسخ القالب "${template.name}" إلى الحافظة',
                                      ),
                                    ),
                                  );
                                }
                              },
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete_outline),
                              tooltip: 'حذف',
                              onPressed: () async {
                                final confirm = await showDialog<bool>(
                                  context: dialogContext,
                                  builder: (context) => AlertDialog(
                                    title: const Text('حذف القالب'),
                                    content: Text(
                                      'سيتم حذف القالب "${template.name}" بشكل نهائي',
                                    ),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.pop(context, false),
                                        child: const Text('إلغاء'),
                                      ),
                                      FilledButton(
                                        style: FilledButton.styleFrom(
                                          backgroundColor: Colors.red,
                                        ),
                                        onPressed: () =>
                                            Navigator.pop(context, true),
                                        child: const Text('حذف'),
                                      ),
                                    ],
                                  ),
                                );

                                if (confirm == true) {
                                  await _deleteTemplate(template);
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(
                                    this.context,
                                  ).showSnackBar(
                                    SnackBar(
                                      content: Text(
                                        'تم حذف القالب "${template.name}"',
                                      ),
                                    ),
                                  );
                                  Navigator.of(
                                    this.context,
                                    rootNavigator: true,
                                  ).pop();
                                }
                              },
                            ),
                          ],
                        ),
                      );
                    },
                    separatorBuilder: (context, _) => const Divider(height: 1),
                    itemCount: _savedTemplates.length,
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('إغلاق'),
            ),
          ],
        );
      },
    );

    if (selected != null) {
      _applyTemplate(selected);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تم تحميل القالب "${selected.name}"')),
        );
      }
    }
  }

  void _exportTemplate() async {
    try {
      final exportName =
          'قالب_${_selectedTemplateType}_${DateTime.now().millisecondsSinceEpoch}';
      final template = _buildCurrentTemplate(exportName);
      final jsonString = const JsonEncoder.withIndent(
        '  ',
      ).convert(template.toJson());

      await Clipboard.setData(ClipboardData(text: jsonString));
      try {
        await SharePlus.instance.share(
          ShareParams(text: jsonString, title: 'قالب ${template.name}'),
        );
      } catch (_) {
        // مشاركة غير مدعومة في بعض المنصات، يكفي النسخ للحافظة
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('تم نسخ ملف القالب إلى الحافظة ويمكن مشاركته الآن'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في التصدير: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _importTemplate() async {
    // أولاً حاول اختيار ملف JSON من النظام، وإذا لم يتم اختيار ملف فاعرض نافذة اللصق
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        allowMultiple: false,
      );

      String? content;
      if (result != null && result.files.isNotEmpty) {
        final file = result.files.first;
        if (file.path != null) {
          final f = File(file.path!);
          content = await f.readAsString();
        } else if (file.bytes != null) {
          content = String.fromCharCodes(file.bytes!);
        }
      }

      if (content == null || content.trim().isEmpty) {
        if (!mounted) return;
        // لم يتم اختيار ملف أو الملف فارغ - افتح مربع لصق JSON
        final TextEditingController controller = TextEditingController();
        final rawJson = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('استيراد قالب من JSON'),
            content: TextField(
              controller: controller,
              maxLines: 12,
              minLines: 8,
              decoration: const InputDecoration(
                hintText: '{ "name": "MyTemplate", ... }',
                border: OutlineInputBorder(),
              ),
              textDirection: TextDirection.ltr,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text.trim()),
                child: const Text('استيراد'),
              ),
            ],
          ),
        );

        if (rawJson == null || rawJson.isEmpty) return;
        content = rawJson;
      }

      // الآن لدينا محتوى JSON في المتغير content
      final Map<String, dynamic> data =
          jsonDecode(content) as Map<String, dynamic>;
      TemplateDocument template = TemplateDocument.fromJson(data);
      final uniqueName = _generateUniqueName(template.name);
      if (uniqueName != template.name) {
        template = template.copyWith(name: uniqueName);
      }

      if (!mounted) return;

      setState(() {
        _savedTemplates.add(template);
      });
      await _persistTemplates();

      _applyTemplate(template);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم استيراد وتطبيق القالب "${template.name}"'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('تعذر قراءة ملف القالب: $e')));
      }
    }
  }

  void _duplicateElement() {
    if (_selectedElement == null) return;

    final duplicate = TemplateElement(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      type: _selectedElement!.type,
      x: _selectedElement!.x + 10,
      y: _selectedElement!.y + 10,
      width: _selectedElement!.width,
      height: _selectedElement!.height,
      label: '${_selectedElement!.label} (نسخة)',
      content: _selectedElement!.content,
      fontSize: _selectedElement!.fontSize,
      fontWeight: _selectedElement!.fontWeight,
      alignment: _selectedElement!.alignment,
      backgroundColor: _selectedElement!.backgroundColor,
      textColor: _selectedElement!.textColor,
      borderColor: _selectedElement!.borderColor,
      borderWidth: _selectedElement!.borderWidth,
      borderRadius: _selectedElement!.borderRadius,
      rotation: _selectedElement!.rotation,
      opacity: _selectedElement!.opacity,
      isVisible: _selectedElement!.isVisible,
    );

    setState(() {
      _elements.add(duplicate);
      _selectedElement = duplicate;
    });
  }

  void _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('تأكيد'),
        content: const Text('هل تريد حذف جميع العناصر؟'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('حذف الكل'),
          ),
        ],
      ),
    );

    if (confirm == true && mounted) {
      setState(() {
        _elements.clear();
        _selectedElement = null;
      });
    }
  }

  void _previewTemplate() async {
    await showDialog(
      context: context,
      builder: (context) => Dialog(
        child: Container(
          width: MediaQuery.of(context).size.width * 0.8,
          height: MediaQuery.of(context).size.height * 0.8,
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'معاينة القالب',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.print),
                        onPressed: () {
                          // TODO: طباعة المعاينة
                          Navigator.pop(context);
                        },
                        tooltip: 'طباعة',
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: Container(
                  color: Colors.grey[300],
                  child: Center(
                    child: Container(
                      width: _pageWidth * 3.78,
                      height: _pageHeight * 3.78,
                      color: Colors.white,
                      child: Stack(
                        children: _elements.map((element) {
                          return Positioned(
                            left: element.x * 3.78,
                            top: element.y * 3.78,
                            child: Container(
                              width: element.width * 3.78,
                              height: element.height * 3.78,
                              decoration: BoxDecoration(
                                color: element.backgroundColor != null
                                    ? Color(element.backgroundColor!)
                                    : null,
                                border: element.borderColor != null
                                    ? Border.all(
                                        color: Color(element.borderColor!),
                                        width: element.borderWidth ?? 1,
                                      )
                                    : null,
                              ),
                              child: _buildElementContent(element, 1.0),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  final Color currentColor;

  const _ColorPickerDialog({required this.currentColor});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late Color _selectedColor;

  @override
  void initState() {
    super.initState();
    _selectedColor = widget.currentColor;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('اختر اللون'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  [
                    Colors.transparent,
                    Colors.white,
                    Colors.black,
                    Colors.red,
                    Colors.pink,
                    Colors.purple,
                    Colors.deepPurple,
                    Colors.indigo,
                    Colors.blue,
                    Colors.lightBlue,
                    Colors.cyan,
                    Colors.teal,
                    Colors.green,
                    Colors.lightGreen,
                    Colors.lime,
                    Colors.yellow,
                    Colors.amber,
                    Colors.orange,
                    Colors.deepOrange,
                    Colors.brown,
                    Colors.grey,
                    Colors.blueGrey,
                  ].map((color) {
                    final bool isSelected =
                        _selectedColor.toARGB32() == color.toARGB32();
                    return InkWell(
                      onTap: () {
                        setState(() {
                          _selectedColor = color;
                        });
                      },
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: color,
                          border: Border.all(
                            color: isSelected ? Colors.blue : Colors.grey,
                            width: isSelected ? 3 : 1,
                          ),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: color == Colors.transparent
                            ? const Icon(
                                Icons.block,
                                color: Colors.red,
                                size: 20,
                              )
                            : null,
                      ),
                    );
                  }).toList(),
            ),
            const SizedBox(height: 20),
            Container(
              width: double.infinity,
              height: 60,
              decoration: BoxDecoration(
                color: _selectedColor,
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _selectedColor == Colors.transparent
                  ? const Center(
                      child: Text(
                        'شفاف',
                        style: TextStyle(
                          color: Colors.black,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(height: 10),
            Text(
              'RGB: ${(_selectedColor.r * 255).round()}, ${(_selectedColor.g * 255).round()}, ${(_selectedColor.b * 255).round()}',
              style: const TextStyle(fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _selectedColor),
          child: const Text('تطبيق'),
        ),
      ],
    );
  }
}

// نموذج عنصر القالب
class TemplateElement {
  String id;
  ElementType type;
  double x;
  double y;
  double width;
  double height;
  String label;
  String? content;
  double? fontSize;
  String? fontWeight;
  String? alignment;
  int? backgroundColor;
  int? textColor;
  int? borderColor;
  double? borderWidth;
  double? borderRadius;
  double? rotation;
  double? opacity;
  bool isVisible;

  TemplateElement({
    required this.id,
    required this.type,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.label,
    this.content,
    this.fontSize,
    this.fontWeight,
    this.alignment,
    this.backgroundColor,
    this.textColor,
    this.borderColor,
    this.borderWidth,
    this.borderRadius,
    this.rotation,
    this.opacity,
    this.isVisible = true,
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'type': type.name,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'label': label,
      'content': content,
      'fontSize': fontSize,
      'fontWeight': fontWeight,
      'alignment': alignment,
      'backgroundColor': backgroundColor,
      'textColor': textColor,
      'borderColor': borderColor,
      'borderWidth': borderWidth,
      'borderRadius': borderRadius,
      'rotation': rotation,
      'opacity': opacity,
      'isVisible': isVisible,
    };
  }

  TemplateElement clone() => TemplateElement.fromJson(toJson());

  factory TemplateElement.fromJson(Map<String, dynamic> json) {
    double toDoubleValue(dynamic value, [double fallback = 0]) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? fallback;
      return fallback;
    }

    int? toIntValue(dynamic value) {
      if (value == null) return null;
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value);
      return null;
    }

    String? toStringValue(dynamic value) => value?.toString();

    ElementType parseElementType(String? raw) {
      if (raw == null) return ElementType.text;
      final normalized = raw.replaceFirst('ElementType.', '');
      return ElementType.values.firstWhere(
        (type) => type.name == normalized,
        orElse: () => ElementType.text,
      );
    }

    return TemplateElement(
      id:
          toStringValue(json['id']) ??
          DateTime.now().millisecondsSinceEpoch.toString(),
      type: parseElementType(json['type']?.toString()),
      x: toDoubleValue(json['x']),
      y: toDoubleValue(json['y']),
      width: toDoubleValue(json['width'], 20),
      height: toDoubleValue(json['height'], 20),
      label: toStringValue(json['label']) ?? 'عنصر',
      content: toStringValue(json['content']),
      fontSize: json['fontSize'] != null
          ? toDoubleValue(json['fontSize'])
          : null,
      fontWeight: toStringValue(json['fontWeight']),
      alignment: toStringValue(json['alignment']),
      backgroundColor: toIntValue(json['backgroundColor']),
      textColor: toIntValue(json['textColor']),
      borderColor: toIntValue(json['borderColor']),
      borderWidth: json['borderWidth'] != null
          ? toDoubleValue(json['borderWidth'])
          : null,
      borderRadius: json['borderRadius'] != null
          ? toDoubleValue(json['borderRadius'])
          : null,
      rotation: json['rotation'] != null
          ? toDoubleValue(json['rotation'])
          : null,
      opacity: json['opacity'] != null
          ? toDoubleValue(json['opacity'], 1.0)
          : null,
      isVisible: json['isVisible'] == null
          ? true
          : (json['isVisible'] is bool
                ? json['isVisible'] as bool
                : json['isVisible'].toString().toLowerCase() != 'false'),
    );
  }
}

class TemplateDocument {
  TemplateDocument({
    required this.name,
    required this.type,
    required this.pageSize,
    required this.pageWidth,
    required this.pageHeight,
    required this.orientation,
    required this.elements,
    required this.marginTop,
    required this.marginBottom,
    required this.marginLeft,
    required this.marginRight,
    required this.snapToGrid,
    required this.showGuides,
    required this.showMargins,
    required this.showRulers,
    required this.gridSpacing,
    this.createdAt,
    this.updatedAt,
  });

  final String name;
  final String type;
  final String pageSize;
  final double pageWidth;
  final double pageHeight;
  final String orientation;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;
  final bool snapToGrid;
  final bool showGuides;
  final bool showMargins;
  final bool showRulers;
  final double gridSpacing;
  final List<TemplateElement> elements;
  final String? createdAt;
  final String? updatedAt;

  TemplateDocument copyWith({
    String? name,
    String? type,
    String? pageSize,
    double? pageWidth,
    double? pageHeight,
    String? orientation,
    double? marginTop,
    double? marginBottom,
    double? marginLeft,
    double? marginRight,
    bool? snapToGrid,
    bool? showGuides,
    bool? showMargins,
    bool? showRulers,
    double? gridSpacing,
    List<TemplateElement>? elements,
    String? createdAt,
    String? updatedAt,
  }) {
    return TemplateDocument(
      name: name ?? this.name,
      type: type ?? this.type,
      pageSize: pageSize ?? this.pageSize,
      pageWidth: pageWidth ?? this.pageWidth,
      pageHeight: pageHeight ?? this.pageHeight,
      orientation: orientation ?? this.orientation,
      elements: elements ?? this.elements,
      marginTop: marginTop ?? this.marginTop,
      marginBottom: marginBottom ?? this.marginBottom,
      marginLeft: marginLeft ?? this.marginLeft,
      marginRight: marginRight ?? this.marginRight,
      snapToGrid: snapToGrid ?? this.snapToGrid,
      showGuides: showGuides ?? this.showGuides,
      showMargins: showMargins ?? this.showMargins,
      showRulers: showRulers ?? this.showRulers,
      gridSpacing: gridSpacing ?? this.gridSpacing,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'type': type,
      'pageSize': pageSize,
      'pageWidth': pageWidth,
      'pageHeight': pageHeight,
      'orientation': orientation,
      'marginTop': marginTop,
      'marginBottom': marginBottom,
      'marginLeft': marginLeft,
      'marginRight': marginRight,
      'snapToGrid': snapToGrid,
      'showGuides': showGuides,
      'showMargins': showMargins,
      'showRulers': showRulers,
      'gridSpacing': gridSpacing,
      'elements': elements.map((e) => e.toJson()).toList(),
      'createdAt': createdAt,
      'updatedAt': updatedAt,
    };
  }

  factory TemplateDocument.fromJson(Map<String, dynamic> json) {
    double toDoubleValue(dynamic value, double fallback) {
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? fallback;
      return fallback;
    }

    bool toBoolValue(dynamic value, bool fallback) {
      if (value is bool) return value;
      if (value is String) return value.toLowerCase() != 'false';
      return fallback;
    }

    List<TemplateElement> parseElements(dynamic raw) {
      if (raw is List) {
        return raw
            .map((item) {
              if (item is TemplateElement) return item;
              if (item is Map<String, dynamic>) {
                return TemplateElement.fromJson(item);
              }
              if (item is Map) {
                return TemplateElement.fromJson(
                  Map<String, dynamic>.from(item),
                );
              }
              return null;
            })
            .whereType<TemplateElement>()
            .toList();
      }
      return [];
    }

    final name = (json['name'] as String?)?.trim();

    return TemplateDocument(
      name: (name == null || name.isEmpty) ? 'قالب بدون اسم' : name,
      type: (json['type'] as String?) ?? 'قالب',
      pageSize: (json['pageSize'] as String?) ?? 'A4',
      pageWidth: toDoubleValue(json['pageWidth'], 210),
      pageHeight: toDoubleValue(json['pageHeight'], 297),
      orientation: (json['orientation'] as String?) ?? 'portrait',
      elements: parseElements(json['elements']),
      marginTop: toDoubleValue(json['marginTop'], 10),
      marginBottom: toDoubleValue(json['marginBottom'], 10),
      marginLeft: toDoubleValue(json['marginLeft'], 10),
      marginRight: toDoubleValue(json['marginRight'], 10),
      snapToGrid: toBoolValue(json['snapToGrid'], true),
      showGuides: toBoolValue(json['showGuides'], true),
      showMargins: toBoolValue(json['showMargins'], true),
      showRulers: toBoolValue(json['showRulers'], true),
      gridSpacing: toDoubleValue(json['gridSpacing'], 5),
      createdAt: json['createdAt']?.toString(),
      updatedAt: json['updatedAt']?.toString(),
    );
  }
}

// أنواع العناصر
enum ElementType {
  text,
  image,
  table,
  line,
  rectangle,
  barcode,
  dateField,
  numberField,
}

// رسم الشبكة المرجعية والأدلة
class GridPainter extends CustomPainter {
  GridPainter({
    required this.gridSpacing,
    required this.pxPerMm,
    required this.showGuides,
    required this.showMargins,
    required this.marginTop,
    required this.marginBottom,
    required this.marginLeft,
    required this.marginRight,
  });

  final double gridSpacing;
  final double pxPerMm;
  final bool showGuides;
  final bool showMargins;
  final double marginTop;
  final double marginBottom;
  final double marginLeft;
  final double marginRight;

  @override
  void paint(Canvas canvas, Size size) {
    final double spacingPx = gridSpacing * pxPerMm;
    if (spacingPx >= 2) {
      final gridPaint = Paint()
        ..color = Colors.grey.withValues(alpha: 0.2)
        ..strokeWidth = 0.5;
      for (double i = 0; i <= size.height; i += spacingPx) {
        canvas.drawLine(Offset(0, i), Offset(size.width, i), gridPaint);
      }
      for (double i = 0; i <= size.width; i += spacingPx) {
        canvas.drawLine(Offset(i, 0), Offset(i, size.height), gridPaint);
      }
    }

    if (showGuides) {
      final guidePaint = Paint()
        ..color = Colors.blue.withValues(alpha: 0.3)
        ..strokeWidth = 1
        ..style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(size.width / 2, 0),
        Offset(size.width / 2, size.height),
        guidePaint,
      );
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        guidePaint,
      );
    }

    if (showMargins) {
      final marginPaint = Paint()
        ..color = Colors.orange.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      final rect = Rect.fromLTWH(
        marginLeft * pxPerMm,
        marginTop * pxPerMm,
        size.width - (marginLeft + marginRight) * pxPerMm,
        size.height - (marginTop + marginBottom) * pxPerMm,
      );
      canvas.drawRect(rect, marginPaint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) {
    return gridSpacing != oldDelegate.gridSpacing ||
        pxPerMm != oldDelegate.pxPerMm ||
        showGuides != oldDelegate.showGuides ||
        showMargins != oldDelegate.showMargins ||
        marginTop != oldDelegate.marginTop ||
        marginBottom != oldDelegate.marginBottom ||
        marginLeft != oldDelegate.marginLeft ||
        marginRight != oldDelegate.marginRight;
  }
}

class RulerPainter extends CustomPainter {
  RulerPainter({
    required this.isHorizontal,
    required this.length,
    required this.pxPerMm,
  });

  final bool isHorizontal;
  final double length;
  final double pxPerMm;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..color = Colors.grey.withValues(alpha: 0.2)
      ..style = PaintingStyle.fill;
    canvas.drawRect(Offset.zero & size, background);

    final tickPaint = Paint()
      ..color = Colors.grey[700]!
      ..strokeWidth = 1;

    for (double mm = 0; mm <= length; mm += 1) {
      final double pos = mm * pxPerMm;
      if (isHorizontal) {
        final double tickHeight = mm % 10 == 0 ? 12 : (mm % 5 == 0 ? 8 : 4);
        canvas.drawLine(
          Offset(pos, size.height),
          Offset(pos, size.height - tickHeight),
          tickPaint,
        );
        if (mm % 10 == 0) {
          _drawLabel(
            canvas,
            mm.toInt().toString(),
            Offset(pos + 2, size.height - 20),
          );
        }
      } else {
        final double tickWidth = mm % 10 == 0 ? 12 : (mm % 5 == 0 ? 8 : 4);
        canvas.drawLine(
          Offset(size.width, pos),
          Offset(size.width - tickWidth, pos),
          tickPaint,
        );
        if (mm % 10 == 0) {
          _drawLabel(
            canvas,
            mm.toInt().toString(),
            Offset(size.width - 24, pos + 2),
          );
        }
      }
    }
  }

  void _drawLabel(Canvas canvas, String text, Offset offset) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(fontSize: 10, color: Colors.black87),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant RulerPainter oldDelegate) {
    return oldDelegate.length != length ||
        oldDelegate.pxPerMm != pxPerMm ||
        oldDelegate.isHorizontal != isHorizontal;
  }
}
