import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'template_positioning_screen.dart';

/// شاشة تصميم وتخصيص قوالب الطباعة
/// 
/// الميزات:
/// - تخصيص الألوان والخطوط
/// - إضافة/حذف عناصر الفاتورة
/// - معاينة حية
/// - حفظ قوالب متعددة
/// - استيراد/تصدير القوالب
class PrintTemplateDesignerScreen extends StatefulWidget {
  final bool isArabic;

  const PrintTemplateDesignerScreen({
    super.key,
    this.isArabic = true,
  });

  @override
  State<PrintTemplateDesignerScreen> createState() =>
      _PrintTemplateDesignerScreenState();
}

class _PrintTemplateDesignerScreenState
    extends State<PrintTemplateDesignerScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  
  // إعدادات العامة
  String _templateName = 'القالب الافتراضي';
  String _paperSize = 'A4';
  String _orientation = 'portrait';
  
  // إعدادات الألوان
  Color _primaryColor = const Color(0xFFD4AF37); // ذهبي
  Color _accentColor = const Color(0xFF2196F3); // أزرق
  Color _textColor = Colors.black;
  Color _headerBgColor = const Color(0xFFF5F5F5);
  
  // إعدادات الخطوط
  double _titleFontSize = 24.0;
  double _headerFontSize = 16.0;
  double _bodyFontSize = 12.0;
  double _footerFontSize = 10.0;
  String _fontFamily = 'Cairo';
  
  // إعدادات الهوامش
  double _marginTop = 20.0;
  double _marginBottom = 20.0;
  double _marginLeft = 20.0;
  double _marginRight = 20.0;
  
  // عناصر الفاتورة
  bool _showLogo = true;
  bool _showCompanyName = true;
  bool _showAddress = true;
  bool _showPhone = true;
  bool _showTaxNumber = true;
  bool _showInvoiceNumber = true;
  bool _showDate = true;
  bool _showCustomerInfo = true;
  bool _showItemsTable = true;
  bool _showPrices = true;
  bool _showTax = true;
  bool _showTotals = true;
  bool _showNotes = true;
  bool _showFooter = true;
  bool _showSignature = false;
  bool _showQRCode = false;
  bool _showBarcode = false;
  
  // تخطيط الصفحة
  String _headerLayout = 'horizontal'; // horizontal, vertical, centered
  String _tableStyle = 'bordered'; // bordered, striped, minimal
  bool _showAlternateRowColors = true;
  bool _showGridLines = true;
  
  // نص مخصص
  String _customHeaderText = '';
  String _customFooterText = 'شكراً لتعاملكم معنا';
  String _companyName = 'محل ياسار للذهب والمجوهرات';
  String _companyAddress = 'المملكة العربية السعودية';
  String _companyPhone = '+966-XXX-XXXX';
  String _companyTaxNumber = '123456789';
  
  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _loadTemplate();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadTemplate() async {
    final prefs = await SharedPreferences.getInstance();
    final templateJson = prefs.getString('print_template');
    if (templateJson != null) {
      final template = json.decode(templateJson);
      setState(() {
        _templateName = template['name'] ?? _templateName;
        _paperSize = template['paperSize'] ?? _paperSize;
        _orientation = template['orientation'] ?? _orientation;
        
        // تحميل الألوان
        if (template['colors'] != null) {
          _primaryColor = Color(template['colors']['primary'] ?? 0xFFD4AF37);
          _accentColor = Color(template['colors']['accent'] ?? 0xFF2196F3);
          _textColor = Color(template['colors']['text'] ?? 0xFF000000);
          _headerBgColor = Color(template['colors']['headerBg'] ?? 0xFFF5F5F5);
        }
        
        // تحميل الخطوط
        if (template['fonts'] != null) {
          _titleFontSize = template['fonts']['title'] ?? _titleFontSize;
          _headerFontSize = template['fonts']['header'] ?? _headerFontSize;
          _bodyFontSize = template['fonts']['body'] ?? _bodyFontSize;
          _footerFontSize = template['fonts']['footer'] ?? _footerFontSize;
        }
        
        // تحميل العناصر
        if (template['elements'] != null) {
          _showLogo = template['elements']['logo'] ?? _showLogo;
          _showCompanyName = template['elements']['companyName'] ?? _showCompanyName;
          _showAddress = template['elements']['address'] ?? _showAddress;
          // ... المزيد من العناصر
        }
      });
    }
  }

  Future<void> _saveTemplate() async {
    final template = {
      'name': _templateName,
      'paperSize': _paperSize,
      'orientation': _orientation,
      'colors': {
        'primary': _primaryColor.value,
        'accent': _accentColor.value,
        'text': _textColor.value,
        'headerBg': _headerBgColor.value,
      },
      'fonts': {
        'title': _titleFontSize,
        'header': _headerFontSize,
        'body': _bodyFontSize,
        'footer': _footerFontSize,
        'family': _fontFamily,
      },
      'margins': {
        'top': _marginTop,
        'bottom': _marginBottom,
        'left': _marginLeft,
        'right': _marginRight,
      },
      'elements': {
        'logo': _showLogo,
        'companyName': _showCompanyName,
        'address': _showAddress,
        'phone': _showPhone,
        'taxNumber': _showTaxNumber,
        'invoiceNumber': _showInvoiceNumber,
        'date': _showDate,
        'customerInfo': _showCustomerInfo,
        'itemsTable': _showItemsTable,
        'prices': _showPrices,
        'tax': _showTax,
        'totals': _showTotals,
        'notes': _showNotes,
        'footer': _showFooter,
        'signature': _showSignature,
        'qrCode': _showQRCode,
        'barcode': _showBarcode,
      },
      'layout': {
        'headerLayout': _headerLayout,
        'tableStyle': _tableStyle,
        'alternateRowColors': _showAlternateRowColors,
        'gridLines': _showGridLines,
      },
      'text': {
        'customHeader': _customHeaderText,
        'customFooter': _customFooterText,
        'companyName': _companyName,
        'companyAddress': _companyAddress,
        'companyPhone': _companyPhone,
        'companyTaxNumber': _companyTaxNumber,
      },
    };

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('print_template', json.encode(template));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.isArabic
                ? '✓ تم حفظ القالب بنجاح'
                : '✓ Template saved successfully',
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
            widget.isArabic ? 'تصميم قالب الطباعة' : 'Print Template Designer',
          ),
          backgroundColor: _primaryColor,
          bottom: TabBar(
            controller: _tabController,
            isScrollable: true,
            tabs: [
              Tab(
                icon: const Icon(Icons.palette),
                text: widget.isArabic ? 'الألوان' : 'Colors',
              ),
              Tab(
                icon: const Icon(Icons.text_fields),
                text: widget.isArabic ? 'الخطوط' : 'Fonts',
              ),
              Tab(
                icon: const Icon(Icons.view_module),
                text: widget.isArabic ? 'العناصر' : 'Elements',
              ),
              Tab(
                icon: const Icon(Icons.dashboard),
                text: widget.isArabic ? 'التخطيط' : 'Layout',
              ),
              Tab(
                icon: const Icon(Icons.preview),
                text: widget.isArabic ? 'المعاينة' : 'Preview',
              ),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.open_with),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const TemplatePositioningScreen(),
                  ),
                );
              },
              tooltip: widget.isArabic ? 'ضبط موقع العناصر' : 'Position Elements',
            ),
            IconButton(
              icon: const Icon(Icons.save),
              onPressed: _saveTemplate,
              tooltip: widget.isArabic ? 'حفظ القالب' : 'Save Template',
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _resetToDefault,
              tooltip: widget.isArabic ? 'إعادة تعيين' : 'Reset',
            ),
          ],
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildColorsTab(),
            _buildFontsTab(),
            _buildElementsTab(),
            _buildLayoutTab(),
            _buildPreviewTab(),
          ],
        ),
      ),
    );
  }

  // تبويب الألوان
  Widget _buildColorsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader(
          widget.isArabic ? 'ألوان القالب' : 'Template Colors',
          Icons.palette,
        ),
        const SizedBox(height: 16),
        
        _buildColorPicker(
          widget.isArabic ? 'اللون الأساسي' : 'Primary Color',
          _primaryColor,
          (color) => setState(() => _primaryColor = color),
        ),
        
        _buildColorPicker(
          widget.isArabic ? 'لون التمييز' : 'Accent Color',
          _accentColor,
          (color) => setState(() => _accentColor = color),
        ),
        
        _buildColorPicker(
          widget.isArabic ? 'لون النص' : 'Text Color',
          _textColor,
          (color) => setState(() => _textColor = color),
        ),
        
        _buildColorPicker(
          widget.isArabic ? 'لون خلفية الرأس' : 'Header Background',
          _headerBgColor,
          (color) => setState(() => _headerBgColor = color),
        ),
        
        const SizedBox(height: 24),
        _buildQuickColorSchemes(),
      ],
    );
  }

  // تبويب الخطوط
  Widget _buildFontsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader(
          widget.isArabic ? 'أحجام الخطوط' : 'Font Sizes',
          Icons.text_fields,
        ),
        const SizedBox(height: 16),
        
        _buildFontSlider(
          widget.isArabic ? 'حجم العنوان' : 'Title Size',
          _titleFontSize,
          16.0,
          36.0,
          (value) => setState(() => _titleFontSize = value),
        ),
        
        _buildFontSlider(
          widget.isArabic ? 'حجم الرأس' : 'Header Size',
          _headerFontSize,
          12.0,
          24.0,
          (value) => setState(() => _headerFontSize = value),
        ),
        
        _buildFontSlider(
          widget.isArabic ? 'حجم النص' : 'Body Size',
          _bodyFontSize,
          8.0,
          16.0,
          (value) => setState(() => _bodyFontSize = value),
        ),
        
        _buildFontSlider(
          widget.isArabic ? 'حجم التذييل' : 'Footer Size',
          _footerFontSize,
          6.0,
          14.0,
          (value) => setState(() => _footerFontSize = value),
        ),
        
        const SizedBox(height: 24),
        _buildSectionHeader(
          widget.isArabic ? 'الهوامش' : 'Margins',
          Icons.space_bar,
        ),
        const SizedBox(height: 16),
        
        _buildMarginSlider(
          widget.isArabic ? 'هامش علوي' : 'Top Margin',
          _marginTop,
          (value) => setState(() => _marginTop = value),
        ),
        
        _buildMarginSlider(
          widget.isArabic ? 'هامش سفلي' : 'Bottom Margin',
          _marginBottom,
          (value) => setState(() => _marginBottom = value),
        ),
        
        _buildMarginSlider(
          widget.isArabic ? 'هامش يمين' : 'Right Margin',
          _marginRight,
          (value) => setState(() => _marginRight = value),
        ),
        
        _buildMarginSlider(
          widget.isArabic ? 'هامش يسار' : 'Left Margin',
          _marginLeft,
          (value) => setState(() => _marginLeft = value),
        ),
      ],
    );
  }

  // تبويب العناصر
  Widget _buildElementsTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader(
          widget.isArabic ? 'عناصر الفاتورة' : 'Invoice Elements',
          Icons.view_module,
        ),
        const SizedBox(height: 16),
        
        _buildElementSwitch(
          widget.isArabic ? 'عرض الشعار' : 'Show Logo',
          Icons.image,
          _showLogo,
          (value) => setState(() => _showLogo = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'اسم الشركة' : 'Company Name',
          Icons.business,
          _showCompanyName,
          (value) => setState(() => _showCompanyName = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'العنوان' : 'Address',
          Icons.location_on,
          _showAddress,
          (value) => setState(() => _showAddress = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'رقم الهاتف' : 'Phone Number',
          Icons.phone,
          _showPhone,
          (value) => setState(() => _showPhone = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'الرقم الضريبي' : 'Tax Number',
          Icons.receipt_long,
          _showTaxNumber,
          (value) => setState(() => _showTaxNumber = value),
        ),
        
        const Divider(height: 32),
        
        _buildElementSwitch(
          widget.isArabic ? 'رقم الفاتورة' : 'Invoice Number',
          Icons.tag,
          _showInvoiceNumber,
          (value) => setState(() => _showInvoiceNumber = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'التاريخ' : 'Date',
          Icons.calendar_today,
          _showDate,
          (value) => setState(() => _showDate = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'معلومات العميل' : 'Customer Info',
          Icons.person,
          _showCustomerInfo,
          (value) => setState(() => _showCustomerInfo = value),
        ),
        
        const Divider(height: 32),
        
        _buildElementSwitch(
          widget.isArabic ? 'جدول الأصناف' : 'Items Table',
          Icons.table_chart,
          _showItemsTable,
          (value) => setState(() => _showItemsTable = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'الأسعار' : 'Prices',
          Icons.attach_money,
          _showPrices,
          (value) => setState(() => _showPrices = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'الضريبة' : 'Tax',
          Icons.percent,
          _showTax,
          (value) => setState(() => _showTax = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'الإجماليات' : 'Totals',
          Icons.calculate,
          _showTotals,
          (value) => setState(() => _showTotals = value),
        ),
        
        const Divider(height: 32),
        
        _buildElementSwitch(
          widget.isArabic ? 'الملاحظات' : 'Notes',
          Icons.notes,
          _showNotes,
          (value) => setState(() => _showNotes = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'التذييل' : 'Footer',
          Icons.view_agenda,
          _showFooter,
          (value) => setState(() => _showFooter = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'التوقيع' : 'Signature',
          Icons.draw,
          _showSignature,
          (value) => setState(() => _showSignature = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'رمز QR' : 'QR Code',
          Icons.qr_code,
          _showQRCode,
          (value) => setState(() => _showQRCode = value),
        ),
        
        _buildElementSwitch(
          widget.isArabic ? 'الباركود' : 'Barcode',
          Icons.barcode_reader,
          _showBarcode,
          (value) => setState(() => _showBarcode = value),
        ),
      ],
    );
  }

  // تبويب التخطيط
  Widget _buildLayoutTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader(
          widget.isArabic ? 'إعدادات الصفحة' : 'Page Settings',
          Icons.description,
        ),
        const SizedBox(height: 16),
        
        _buildDropdown(
          widget.isArabic ? 'حجم الورق' : 'Paper Size',
          _paperSize,
          ['A4', 'A5', 'Letter', 'Thermal'],
          (value) => setState(() => _paperSize = value!),
        ),
        
        _buildDropdown(
          widget.isArabic ? 'اتجاه الصفحة' : 'Orientation',
          _orientation,
          ['portrait', 'landscape'],
          (value) => setState(() => _orientation = value!),
          displayValues: {
            'portrait': widget.isArabic ? 'عمودي' : 'Portrait',
            'landscape': widget.isArabic ? 'أفقي' : 'Landscape',
          },
        ),
        
        const SizedBox(height: 24),
        _buildSectionHeader(
          widget.isArabic ? 'تخطيط الرأس' : 'Header Layout',
          Icons.view_day,
        ),
        const SizedBox(height: 16),
        
        _buildDropdown(
          widget.isArabic ? 'نمط الرأس' : 'Header Style',
          _headerLayout,
          ['horizontal', 'vertical', 'centered'],
          (value) => setState(() => _headerLayout = value!),
          displayValues: {
            'horizontal': widget.isArabic ? 'أفقي' : 'Horizontal',
            'vertical': widget.isArabic ? 'عمودي' : 'Vertical',
            'centered': widget.isArabic ? 'متمركز' : 'Centered',
          },
        ),
        
        const SizedBox(height: 24),
        _buildSectionHeader(
          widget.isArabic ? 'نمط الجدول' : 'Table Style',
          Icons.table_chart,
        ),
        const SizedBox(height: 16),
        
        _buildDropdown(
          widget.isArabic ? 'تصميم الجدول' : 'Table Design',
          _tableStyle,
          ['bordered', 'striped', 'minimal'],
          (value) => setState(() => _tableStyle = value!),
          displayValues: {
            'bordered': widget.isArabic ? 'حدود' : 'Bordered',
            'striped': widget.isArabic ? 'مخطط' : 'Striped',
            'minimal': widget.isArabic ? 'بسيط' : 'Minimal',
          },
        ),
        
        const SizedBox(height: 16),
        
        SwitchListTile(
          title: Text(widget.isArabic ? 'ألوان متناوبة للصفوف' : 'Alternate Row Colors'),
          value: _showAlternateRowColors,
          onChanged: (value) => setState(() => _showAlternateRowColors = value),
          secondary: const Icon(Icons.format_paint),
        ),
        
        SwitchListTile(
          title: Text(widget.isArabic ? 'خطوط الشبكة' : 'Grid Lines'),
          value: _showGridLines,
          onChanged: (value) => setState(() => _showGridLines = value),
          secondary: const Icon(Icons.grid_on),
        ),
        
        const SizedBox(height: 24),
        _buildSectionHeader(
          widget.isArabic ? 'نصوص مخصصة' : 'Custom Text',
          Icons.edit,
        ),
        const SizedBox(height: 16),
        
        TextField(
          controller: TextEditingController(text: _companyName),
          decoration: InputDecoration(
            labelText: widget.isArabic ? 'اسم الشركة' : 'Company Name',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.business),
          ),
          onChanged: (value) => _companyName = value,
        ),
        const SizedBox(height: 16),
        
        TextField(
          controller: TextEditingController(text: _companyAddress),
          decoration: InputDecoration(
            labelText: widget.isArabic ? 'العنوان' : 'Address',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.location_on),
          ),
          onChanged: (value) => _companyAddress = value,
        ),
        const SizedBox(height: 16),
        
        TextField(
          controller: TextEditingController(text: _customFooterText),
          decoration: InputDecoration(
            labelText: widget.isArabic ? 'نص التذييل' : 'Footer Text',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.text_fields),
          ),
          onChanged: (value) => _customFooterText = value,
        ),
      ],
    );
  }

  // تبويب المعاينة
  Widget _buildPreviewTab() {
    return Container(
      color: Colors.grey.shade200,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Container(
            width: _paperSize == 'A4' ? 595 : 420,
            decoration: BoxDecoration(
              color: Colors.white,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: _buildPreviewContent(),
          ),
        ),
      ),
    );
  }

  Widget _buildPreviewContent() {
    return Padding(
      padding: EdgeInsets.all(_marginTop),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // رأس الفاتورة
          if (_showCompanyName || _showLogo)
            _buildPreviewHeader(),
          
          const SizedBox(height: 24),
          
          // معلومات الفاتورة
          if (_showInvoiceNumber || _showDate)
            _buildPreviewInvoiceInfo(),
          
          const SizedBox(height: 24),
          
          // جدول الأصناف
          if (_showItemsTable)
            _buildPreviewItemsTable(),
          
          const SizedBox(height: 24),
          
          // الإجماليات
          if (_showTotals)
            _buildPreviewTotals(),
          
          const SizedBox(height: 24),
          
          // التذييل
          if (_showFooter)
            _buildPreviewFooter(),
        ],
      ),
    );
  }

  Widget _buildPreviewHeader() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _headerBgColor,
        border: Border(
          bottom: BorderSide(color: _primaryColor, width: 2),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_showCompanyName)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _companyName,
                  style: TextStyle(
                    fontSize: _titleFontSize,
                    fontWeight: FontWeight.bold,
                    color: _primaryColor,
                  ),
                ),
                if (_showAddress)
                  Text(
                    _companyAddress,
                    style: TextStyle(fontSize: _bodyFontSize, color: _textColor),
                  ),
              ],
            ),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _primaryColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.isArabic ? 'فاتورة' : 'INVOICE',
              style: TextStyle(
                color: Colors.white,
                fontSize: _headerFontSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewInvoiceInfo() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        if (_showInvoiceNumber)
          Text(
            '${widget.isArabic ? 'رقم الفاتورة:' : 'Invoice No:'} #12345',
            style: TextStyle(fontSize: _bodyFontSize),
          ),
        if (_showDate)
          Text(
            '${widget.isArabic ? 'التاريخ:' : 'Date:'} 2025-11-14',
            style: TextStyle(fontSize: _bodyFontSize),
          ),
      ],
    );
  }

  Widget _buildPreviewItemsTable() {
    return Table(
      border: _showGridLines
          ? TableBorder.all(color: Colors.grey.shade300)
          : null,
      children: [
        // رأس الجدول
        TableRow(
          decoration: BoxDecoration(color: _primaryColor.withValues(alpha: 0.1)),
          children: [
            _buildTableCell('#', isHeader: true),
            _buildTableCell(widget.isArabic ? 'الصنف' : 'Item', isHeader: true),
            _buildTableCell(widget.isArabic ? 'الكمية' : 'Qty', isHeader: true),
            if (_showPrices)
              _buildTableCell(widget.isArabic ? 'السعر' : 'Price', isHeader: true),
          ],
        ),
        // صف عينة
        TableRow(
          decoration: _showAlternateRowColors
              ? BoxDecoration(color: Colors.grey.shade50)
              : null,
          children: [
            _buildTableCell('1'),
            _buildTableCell(widget.isArabic ? 'خاتم ذهب' : 'Gold Ring'),
            _buildTableCell('1'),
            if (_showPrices)
              _buildTableCell('1,250.00'),
          ],
        ),
      ],
    );
  }

  Widget _buildTableCell(String text, {bool isHeader = false}) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Text(
        text,
        style: TextStyle(
          fontSize: isHeader ? _headerFontSize : _bodyFontSize,
          fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
          color: _textColor,
        ),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildPreviewTotals() {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        width: 200,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(widget.isArabic ? 'المجموع:' : 'Subtotal:',
                    style: TextStyle(fontSize: _bodyFontSize)),
                Text('1,250.00', style: TextStyle(fontSize: _bodyFontSize)),
              ],
            ),
            if (_showTax) ...[
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(widget.isArabic ? 'الضريبة:' : 'Tax:',
                      style: TextStyle(fontSize: _bodyFontSize)),
                  Text('187.50', style: TextStyle(fontSize: _bodyFontSize)),
                ],
              ),
            ],
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  widget.isArabic ? 'الإجمالي:' : 'Total:',
                  style: TextStyle(
                    fontSize: _bodyFontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  '1,437.50',
                  style: TextStyle(
                    fontSize: _bodyFontSize,
                    fontWeight: FontWeight.bold,
                    color: _primaryColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewFooter() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Colors.grey.shade300)),
      ),
      child: Center(
        child: Text(
          _customFooterText,
          style: TextStyle(
            fontSize: _footerFontSize,
            color: Colors.grey.shade600,
          ),
        ),
      ),
    );
  }

  // أدوات مساعدة
  Widget _buildSectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: _primaryColor),
        const SizedBox(width: 12),
        Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: _primaryColor,
          ),
        ),
      ],
    );
  }

  Widget _buildColorPicker(
    String label,
    Color currentColor,
    Function(Color) onColorChanged,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(label),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: currentColor,
                border: Border.all(color: Colors.grey),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => _showColorPickerDialog(currentColor, onColorChanged),
            ),
          ],
        ),
      ),
    );
  }

  void _showColorPickerDialog(Color currentColor, Function(Color) onColorChanged) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'اختر اللون' : 'Pick Color'),
        content: SingleChildScrollView(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              const Color(0xFFD4AF37), // ذهبي
              const Color(0xFF2196F3), // أزرق
              const Color(0xFF4CAF50), // أخضر
              const Color(0xFFFF9800), // برتقالي
              const Color(0xFFF44336), // أحمر
              const Color(0xFF9C27B0), // بنفسجي
              Colors.black,
              Colors.grey,
              Colors.white,
            ].map((color) {
              return GestureDetector(
                onTap: () {
                  onColorChanged(color);
                  Navigator.pop(context);
                },
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: color,
                    border: Border.all(color: Colors.grey),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }

  Widget _buildFontSlider(
    String label,
    double value,
    double min,
    double max,
    Function(double) onChanged,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: value,
                    min: min,
                    max: max,
                    divisions: ((max - min) * 2).toInt(),
                    label: value.toStringAsFixed(0),
                    onChanged: onChanged,
                  ),
                ),
                Text('${value.toStringAsFixed(0)}pt'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMarginSlider(
    String label,
    double value,
    Function(double) onChanged,
  ) {
    return _buildFontSlider(label, value, 0.0, 50.0, onChanged);
  }

  Widget _buildElementSwitch(
    String label,
    IconData icon,
    bool value,
    Function(bool) onChanged,
  ) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: SwitchListTile(
        title: Text(label),
        secondary: Icon(icon, color: _primaryColor),
        value: value,
        onChanged: onChanged,
      ),
    );
  }

  Widget _buildDropdown(
    String label,
    String value,
    List<String> items,
    Function(String?) onChanged, {
    Map<String, String>? displayValues,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              value: value,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
              ),
              items: items.map((item) {
                return DropdownMenuItem(
                  value: item,
                  child: Text(displayValues?[item] ?? item),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickColorSchemes() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.isArabic ? 'مجموعات ألوان جاهزة' : 'Quick Color Schemes',
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _buildColorSchemeCard(
              widget.isArabic ? 'ذهبي كلاسيكي' : 'Classic Gold',
              const Color(0xFFD4AF37),
              const Color(0xFF2196F3),
            ),
            _buildColorSchemeCard(
              widget.isArabic ? 'أزرق احترافي' : 'Professional Blue',
              const Color(0xFF2196F3),
              const Color(0xFF03A9F4),
            ),
            _buildColorSchemeCard(
              widget.isArabic ? 'أخضر طبيعي' : 'Natural Green',
              const Color(0xFF4CAF50),
              const Color(0xFF8BC34A),
            ),
            _buildColorSchemeCard(
              widget.isArabic ? 'أحمر أنيق' : 'Elegant Red',
              const Color(0xFFF44336),
              const Color(0xFFE91E63),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildColorSchemeCard(String name, Color primary, Color accent) {
    return InkWell(
      onTap: () {
        setState(() {
          _primaryColor = primary;
          _accentColor = accent;
        });
      },
      child: Container(
        width: 150,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey.shade300),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: primary,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              name,
              style: const TextStyle(fontSize: 12),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  void _resetToDefault() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(widget.isArabic ? 'إعادة تعيين' : 'Reset'),
        content: Text(
          widget.isArabic
              ? 'هل تريد إعادة تعيين جميع الإعدادات للقيم الافتراضية؟'
              : 'Do you want to reset all settings to default values?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(widget.isArabic ? 'إلغاء' : 'Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _primaryColor = const Color(0xFFD4AF37);
                _accentColor = const Color(0xFF2196F3);
                _textColor = Colors.black;
                _headerBgColor = const Color(0xFFF5F5F5);
                _titleFontSize = 24.0;
                _headerFontSize = 16.0;
                _bodyFontSize = 12.0;
                _footerFontSize = 10.0;
                _marginTop = 20.0;
                _marginBottom = 20.0;
                _marginLeft = 20.0;
                _marginRight = 20.0;
                // إعادة تعيين جميع العناصر
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
