"""
API Routes للقيود الدورية (Recurring Journal Entries)
======================================================
"""

from flask import jsonify, request
from datetime import datetime
from routes import api  # استخدام نفس الـ blueprint
from models import db
from recurring_journal_system import (
    RecurringJournalTemplate,
    RecurringJournalLine,
    create_recurring_template,
    process_recurring_journals
)


@api.route('/recurring_templates', methods=['GET'])
def get_recurring_templates():
    """جلب جميع قوالب القيود الدورية"""
    try:
        templates = RecurringJournalTemplate.query.order_by(
            RecurringJournalTemplate.created_at.desc()
        ).all()
        
        return jsonify([template.to_dict() for template in templates]), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/<int:template_id>', methods=['GET'])
def get_recurring_template(template_id):
    """جلب قالب قيد دوري محدد"""
    try:
        template = RecurringJournalTemplate.query.get_or_404(template_id)
        return jsonify(template.to_dict()), 200
    except Exception as e:
        return jsonify({'error': str(e)}), 404


@api.route('/recurring_templates', methods=['POST'])
def create_recurring_template_endpoint():
    """إنشاء قالب قيد دوري جديد"""
    try:
        data = request.get_json()
        
        # التحقق من البيانات المطلوبة
        required_fields = ['name', 'description', 'frequency', 'start_date', 'lines']
        for field in required_fields:
            if field not in data:
                return jsonify({'error': f'الحقل {field} مطلوب'}), 400
        
        # تحويل التاريخ
        start_date = datetime.fromisoformat(data['start_date'])
        end_date = datetime.fromisoformat(data['end_date']) if data.get('end_date') else None
        
        # إنشاء القالب
        template = create_recurring_template(
            name=data['name'],
            description=data['description'],
            frequency=data['frequency'],
            start_date=start_date,
            lines_data=data['lines'],
            interval=data.get('interval', 1),
            end_date=end_date,
            preferred_day=data.get('preferred_day_of_month', 1),
            created_by=data.get('created_by', 'system')
        )
        
        return jsonify({
            'message': 'تم إنشاء القالب بنجاح',
            'template': template.to_dict()
        }), 201
        
    except ValueError as e:
        return jsonify({'error': f'خطأ في صيغة التاريخ: {str(e)}'}), 400
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/<int:template_id>', methods=['PUT'])
def update_recurring_template(template_id):
    """تحديث قالب قيد دوري"""
    try:
        template = RecurringJournalTemplate.query.get_or_404(template_id)
        data = request.get_json()
        
        # تحديث الحقول الأساسية
        if 'name' in data:
            template.name = data['name']
        if 'description' in data:
            template.description = data['description']
        if 'frequency' in data:
            template.frequency = data['frequency']
        if 'interval' in data:
            template.interval = data['interval']
        if 'preferred_day_of_month' in data:
            template.preferred_day_of_month = data['preferred_day_of_month']
        if 'is_active' in data:
            template.is_active = data['is_active']
        if 'auto_create' in data:
            template.auto_create = data['auto_create']
        
        # تحديث التواريخ
        if 'start_date' in data:
            template.start_date = datetime.fromisoformat(data['start_date'])
        if 'end_date' in data:
            template.end_date = datetime.fromisoformat(data['end_date']) if data['end_date'] else None
        if 'next_run_date' in data:
            template.next_run_date = datetime.fromisoformat(data['next_run_date'])
        
        # تحديث الخطوط إذا تم توفيرها
        if 'lines' in data:
            # حذف الخطوط القديمة
            RecurringJournalLine.query.filter_by(template_id=template_id).delete()
            
            # إضافة الخطوط الجديدة
            for line_data in data['lines']:
                new_line = RecurringJournalLine(
                    template_id=template.id,
                    account_id=line_data['account_id'],
                    cash_debit=line_data.get('cash_debit', 0.0),
                    cash_credit=line_data.get('cash_credit', 0.0),
                    debit_18k=line_data.get('debit_18k', 0.0),
                    credit_18k=line_data.get('credit_18k', 0.0),
                    debit_21k=line_data.get('debit_21k', 0.0),
                    credit_21k=line_data.get('credit_21k', 0.0),
                    debit_22k=line_data.get('debit_22k', 0.0),
                    credit_22k=line_data.get('credit_22k', 0.0),
                    debit_24k=line_data.get('debit_24k', 0.0),
                    credit_24k=line_data.get('credit_24k', 0.0),
                )
                db.session.add(new_line)
        
        db.session.commit()
        
        return jsonify({
            'message': 'تم تحديث القالب بنجاح',
            'template': template.to_dict()
        }), 200
        
    except ValueError as e:
        return jsonify({'error': f'خطأ في صيغة التاريخ: {str(e)}'}), 400
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/<int:template_id>', methods=['DELETE'])
def delete_recurring_template(template_id):
    """حذف قالب قيد دوري"""
    try:
        template = RecurringJournalTemplate.query.get_or_404(template_id)
        
        db.session.delete(template)
        db.session.commit()
        
        return jsonify({'message': 'تم حذف القالب بنجاح'}), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/<int:template_id>/toggle_active', methods=['POST'])
def toggle_template_active(template_id):
    """تفعيل/تعطيل قالب قيد دوري"""
    try:
        template = RecurringJournalTemplate.query.get_or_404(template_id)
        
        template.is_active = not template.is_active
        db.session.commit()
        
        status = 'تم التفعيل' if template.is_active else 'تم التعطيل'
        
        return jsonify({
            'message': f'{status} بنجاح',
            'is_active': template.is_active
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/<int:template_id>/create_entry', methods=['POST'])
def create_entry_from_template(template_id):
    """إنشاء قيد يدوياً من قالب"""
    try:
        template = RecurringJournalTemplate.query.get_or_404(template_id)
        
        # إنشاء القيد
        entry = template.create_journal_entry()
        
        return jsonify({
            'message': 'تم إنشاء القيد بنجاح',
            'entry': {
                'id': entry.id,
                'entry_number': entry.entry_number,
                'date': entry.date.isoformat(),
                'description': entry.description
            }
        }), 201
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/process_all', methods=['POST'])
def process_all_recurring():
    """معالجة جميع القيود الدورية المستحقة"""
    try:
        # الحصول على التاريخ المطلوب (افتراضياً اليوم)
        data = request.get_json() or {}
        check_date = None
        
        if 'check_date' in data:
            check_date = datetime.fromisoformat(data['check_date'])
        
        # معالجة القيود
        created_entries = process_recurring_journals(check_date)
        
        return jsonify({
            'message': f'تم إنشاء {len(created_entries)} قيد بنجاح',
            'entries': [
                {
                    'id': entry.id,
                    'entry_number': entry.entry_number,
                    'date': entry.date.isoformat(),
                    'description': entry.description
                }
                for entry in created_entries
            ]
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'error': str(e)}), 500


@api.route('/recurring_templates/due_count', methods=['GET'])
def get_due_templates_count():
    """الحصول على عدد القيود الدورية المستحقة"""
    try:
        now = datetime.now()
        
        due_templates = RecurringJournalTemplate.query.filter(
            RecurringJournalTemplate.is_active == True,
            RecurringJournalTemplate.auto_create == True,
            RecurringJournalTemplate.next_run_date <= now
        ).all()
        
        # تصفية القوالب التي لم تنتهي
        active_due = [
            t for t in due_templates 
            if t.end_date is None or t.end_date >= now
        ]
        
        return jsonify({
            'due_count': len(active_due),
            'due_templates': [
                {
                    'id': t.id,
                    'name': t.name,
                    'next_run_date': t.next_run_date.isoformat()
                }
                for t in active_due
            ]
        }), 200
        
    except Exception as e:
        return jsonify({'error': str(e)}), 500
