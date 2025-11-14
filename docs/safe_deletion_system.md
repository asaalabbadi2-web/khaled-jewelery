# تطوير نظام الحذف الآمن للقيود المحاسبية
# Safe Journal Entry Deletion System Enhancement

## المشكلة الحالية:
الحذف الحالي نهائي ويؤثر على:
- أرصدة الحسابات
- كشوفات العملاء/الموردين  
- تقارير المخزون
- التوازن المحاسبي

## الحل المقترح: نظام الحذف الآمن

### 1. إضافة حقول للتتبع في نموذج JournalEntry:

```python
class JournalEntry(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    date = db.Column(db.DateTime, nullable=False, default=db.func.now())
    description = db.Column(db.String(200))
    
    # حقول جديدة للحذف الآمن
    is_deleted = db.Column(db.Boolean, default=False, nullable=False)
    deleted_at = db.Column(db.DateTime, nullable=True)
    deleted_by = db.Column(db.String(100), nullable=True)  # اسم المستخدم
    deletion_reason = db.Column(db.String(500), nullable=True)
    
    # للاسترجاع
    restored_at = db.Column(db.DateTime, nullable=True)
    restored_by = db.Column(db.String(100), nullable=True)
    
    lines = db.relationship('JournalEntryLine', backref='journal_entry', lazy=True, cascade="all, delete-orphan")
    
    # دالة للحذف الناعم
    def soft_delete(self, deleted_by, reason=None):
        self.is_deleted = True
        self.deleted_at = db.func.now()
        self.deleted_by = deleted_by
        self.deletion_reason = reason
        
    # دالة للاسترجاع
    def restore(self, restored_by):
        self.is_deleted = False
        self.restored_at = db.func.now()
        self.restored_by = restored_by
        
    # تحديث to_dict لإخفاء المحذوف
    def to_dict(self, include_deleted=False):
        if self.is_deleted and not include_deleted:
            return None
            
        return {
            'id': self.id,
            'date': self.date.isoformat(),
            'description': self.description,
            'lines': [line.to_dict() for line in self.lines if not line.is_deleted],
            'is_deleted': self.is_deleted,
            'deleted_at': self.deleted_at.isoformat() if self.deleted_at else None,
            'deleted_by': self.deleted_by
        }
```

### 2. تحديث JournalEntryLine أيضاً:

```python
class JournalEntryLine(db.Model):
    id = db.Column(db.Integer, primary_key=True)
    journal_entry_id = db.Column(db.Integer, db.ForeignKey('journal_entry.id'), nullable=False)
    account_id = db.Column(db.Integer, db.ForeignKey('account.id'), nullable=False)
    
    # حقول الحذف الناعم
    is_deleted = db.Column(db.Boolean, default=False, nullable=False)
    deleted_at = db.Column(db.DateTime, nullable=True)
    
    # ... باقي الحقول
```

### 3. تحديث API للحذف الآمن:

```python
@api.route('/journal_entries/<int:id>/soft_delete', methods=['POST'])
def soft_delete_journal_entry(id):
    entry = JournalEntry.query.get_or_404(id)
    data = request.get_json()
    
    # التحقق من الصلاحيات
    user = data.get('user', 'غير محدد')
    reason = data.get('reason', '')
    
    # فحوصات أمان
    if not _can_delete_entry(entry):
        return jsonify({
            'error': 'لا يمكن حذف هذا القيد',
            'reason': 'القيد مرتبط بمعاملات أخرى'
        }), 400
    
    try:
        entry.soft_delete(user, reason)
        
        # تحديث الأرصدة (عكس القيد)
        _reverse_entry_effects(entry)
        
        db.session.commit()
        
        # تسجيل في log
        _log_deletion(entry.id, user, reason)
        
        return jsonify({
            'result': 'success',
            'message': 'تم حذف القيد بنجاح',
            'can_restore': True
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

@api.route('/journal_entries/<int:id>/restore', methods=['POST'])
def restore_journal_entry(id):
    entry = JournalEntry.query.filter_by(id=id, is_deleted=True).first_or_404()
    data = request.get_json()
    user = data.get('user', 'غير محدد')
    
    try:
        # إعادة تطبيق تأثيرات القيد
        _apply_entry_effects(entry)
        
        entry.restore(user)
        db.session.commit()
        
        _log_restoration(entry.id, user)
        
        return jsonify({
            'result': 'success',
            'message': 'تم استرجاع القيد بنجاح'
        })
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500

def _can_delete_entry(entry):
    """فحص إمكانية حذف القيد"""
    # فحص إذا كان القيد مرتبط بفواتير
    if entry.description and 'فاتورة' in entry.description:
        return False
        
    # فحص التواريخ - منع حذف قيود قديمة
    days_old = (datetime.now() - entry.date).days
    if days_old > 30:  # أكثر من شهر
        return False
        
    return True

def _reverse_entry_effects(entry):
    """عكس تأثيرات القيد على الأرصدة"""
    for line in entry.lines:
        account = line.account
        
        # عكس المبالغ النقدية
        if line.cash_debit > 0:
            # إذا كان مدين، اطرحه من الرصيد
            account.balance -= line.cash_debit
        if line.cash_credit > 0:
            # إذا كان دائن، أضفه للرصيد
            account.balance += line.cash_credit
            
        # عكس كميات الذهب
        # ... منطق مشابه للذهب

def _apply_entry_effects(entry):
    """إعادة تطبيق تأثيرات القيد"""
    # عكس _reverse_entry_effects
    pass

def _log_deletion(entry_id, user, reason):
    """تسجيل عملية الحذف"""
    # إنشاء سجل في جدول منفصل للـ audit trail
    pass
```

### 4. تحديث الاستعلامات لإخفاء المحذوف:

```python
@api.route('/journal_entries', methods=['GET'])
def get_journal_entries():
    # إخفاء القيود المحذوفة افتراضياً
    entries = JournalEntry.query.filter_by(is_deleted=False).order_by(JournalEntry.date.desc()).all()
    return jsonify([entry.to_dict() for entry in entries])

@api.route('/journal_entries/deleted', methods=['GET'])
def get_deleted_journal_entries():
    """عرض القيود المحذوفة للمراجعة/الاسترجاع"""
    entries = JournalEntry.query.filter_by(is_deleted=True).order_by(JournalEntry.deleted_at.desc()).all()
    return jsonify([entry.to_dict(include_deleted=True) for entry in entries])
```

### 5. واجهة المستخدم المحدثة:

```dart
// في JournalEntriesListScreen
Future<void> _deleteEntry(int id, String description) async {
  final reason = await _showDeleteReasonDialog();
  if (reason == null) return;
  
  final confirmed = await _showDeleteConfirmation(description, reason);
  if (!confirmed) return;
  
  try {
    await _apiService.softDeleteJournalEntry(id, 'المستخدم الحالي', reason);
    _showSnackBar('تم حذف القيد بنجاح (يمكن الاسترجاع خلال 30 يوم)');
    await _refreshData();
  } catch (e) {
    _showSnackBar('فشل حذف القيد: $e', isError: true);
  }
}

Future<String?> _showDeleteReasonDialog() async {
  final controller = TextEditingController();
  return await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('سبب الحذف'),
      content: TextField(
        controller: controller,
        decoration: InputDecoration(
          hintText: 'اكتب سبب حذف هذا القيد...',
          border: OutlineInputBorder(),
        ),
        maxLines: 3,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('إلغاء'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text('متابعة'),
        ),
      ],
    ),
  );
}
```

### 6. شاشة إدارة القيود المحذوفة:

```dart
class DeletedJournalEntriesScreen extends StatelessWidget {
  // شاشة لعرض القيود المحذوفة
  // مع إمكانية الاسترجاع أو الحذف النهائي
}
```

## الفوائد:

### ✅ الأمان المحاسبي:
- **تتبع كامل** لعمليات الحذف
- **إمكانية الاسترجاع** خلال فترة محددة
- **منع الحذف العرضي** للقيود المهمة
- **audit trail شامل**

### ✅ سلامة البيانات:
- **الأرصدة محفوظة** - تُعكس عند الحذف وتُعاد عند الاسترجاع
- **التقارير دقيقة** - لا تُظهر القيود المحذوفة
- **إمكانية المراجعة** للقيود المحذوفة

### ✅ تجربة المستخدم:
- **تأكيد مزدوج** مع كتابة السبب
- **رسائل واضحة** عن إمكانية الاسترجاع
- **واجهة منفصلة** لإدارة المحذوف

## الخطوات للتطبيق:

1. **Migration للقاعدة** - إضافة الحقول الجديدة
2. **تحديث النماذج** - Models with soft delete
3. **تحديث API** - endpoints جديدة
4. **تحديث Flutter** - UI محدثة
5. **اختبار شامل** - للتأكد من سلامة البيانات

هل تريد أن أبدأ بتطبيق هذا النظام؟