"""
نظام التحكم بالترحيل (Posting Control System)
================================================

هذا الملف يوفر endpoints للتحكم بترحيل الفواتير والقيود:

1. ترحيل فاتورة واحدة أو مجموعة
2. إلغاء ترحيل فاتورة
3. ترحيل قيد واحد أو مجموعة
4. إلغاء ترحيل قيد
5. عرض الفواتير/القيود غير المرحلة

الاستخدام:
-----------
from posting_routes import posting_bp
app.register_blueprint(posting_bp, url_prefix='/api')
"""

from flask import Blueprint, request, jsonify, g
from datetime import datetime
from models import db, Invoice, JournalEntry, Account, Customer, Supplier, AuditLog
from sqlalchemy import func
import json
from auth_decorators import require_permission, optional_auth

posting_bp = Blueprint('posting', __name__)

# ==========================================
# 📋 عرض الفواتير/القيود حسب حالة الترحيل
# ==========================================

@posting_bp.route('/invoices/unposted', methods=['GET'])
@require_permission('invoice.view')
def get_unposted_invoices():
    """عرض جميع الفواتير غير المرحلة"""
    try:
        invoices = Invoice.query.filter_by(is_posted=False).order_by(Invoice.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(invoices),
            'invoices': [inv.to_dict() for inv in invoices]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/invoices/posted', methods=['GET'])
@require_permission('invoice.view')
def get_posted_invoices():
    """عرض جميع الفواتير المرحلة"""
    try:
        invoices = Invoice.query.filter_by(is_posted=True).order_by(Invoice.posted_at.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(invoices),
            'invoices': [inv.to_dict() for inv in invoices]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/unposted', methods=['GET'])
@require_permission('journal.view')
def get_unposted_entries():
    """عرض جميع القيود غير المرحلة"""
    try:
        entries = JournalEntry.query.filter_by(
            is_posted=False, 
            is_deleted=False
        ).order_by(JournalEntry.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(entries),
            'entries': [entry.to_dict() for entry in entries]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/posted', methods=['GET'])
@require_permission('journal.view')
def get_posted_entries():
    """عرض جميع القيود المرحلة"""
    try:
        entries = JournalEntry.query.filter_by(
            is_posted=True,
            is_deleted=False
        ).order_by(JournalEntry.posted_at.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(entries),
            'entries': [entry.to_dict() for entry in entries]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# ✅ ترحيل الفواتير
# ==========================================

@posting_bp.route('/invoices/post/<int:invoice_id>', methods=['POST'])
@require_permission('invoice.post')
def post_invoice(invoice_id):
    """
    ترحيل فاتورة واحدة
    
    Body:
    {
        "posted_by": "اسم المستخدم"
    }
    
    يتطلب صلاحية: invoice.post
    """
    try:
        # استخدام اسم المستخدم المصادق عليه
        posted_by = g.current_user.username
        
        invoice = Invoice.query.get(invoice_id)
        if not invoice:
            return jsonify({'success': False, 'message': 'الفاتورة غير موجودة'}), 404
        
        if invoice.is_posted:
            return jsonify({
                'success': False, 
                'message': 'الفاتورة مرحلة بالفعل'
            }), 400
        
        # ترحيل الفاتورة
        invoice.is_posted = True
        invoice.posted_at = datetime.now()
        invoice.posted_by = posted_by
        
        db.session.commit()
        
        # 📋 تسجيل في Audit Log
        try:
            details = json.dumps({
                'invoice_type': invoice.invoice_type,
                'total': float(invoice.total) if invoice.total else 0,
                'date': str(invoice.date),
                'customer_id': invoice.customer_id if hasattr(invoice, 'customer_id') else None,
            }, ensure_ascii=False)
            
            AuditLog.log_action(
                user_name=posted_by,
                action='post_invoice',
                entity_type='Invoice',
                entity_id=invoice_id,
                entity_number=getattr(invoice, 'invoice_number', None),
                details=details,
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=True
            )
        except Exception as log_error:
            print(f"خطأ في تسجيل Audit Log: {log_error}")
        
        return jsonify({
            'success': True,
            'message': 'تم ترحيل الفاتورة بنجاح',
            'invoice': invoice.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        
        # 📋 تسجيل الفشل في Audit Log
        try:
            posted_by = g.current_user.username if hasattr(g, 'current_user') else 'النظام'
            AuditLog.log_action(
                user_name=posted_by,
                action='post_invoice',
                entity_type='Invoice',
                entity_id=invoice_id,
                entity_number=None,
                details=None,
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent'),
                success=False,
                error_message=str(e)
            )
        except:
            pass
        
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/invoices/post-batch', methods=['POST'])
@require_permission('invoice.post')
def post_invoices_batch():
    """
    ترحيل مجموعة فواتير
    
    Body:
    {
        "invoice_ids": [1, 2, 3, ...]
    }
    
    يتطلب صلاحية: invoice.post
    """
    try:
        posted_by = g.current_user.username
        data = request.get_json()
        invoice_ids = data.get('invoice_ids', [])
        
        if not invoice_ids:
            return jsonify({'success': False, 'message': 'لم يتم تحديد أي فواتير'}), 400
        
        invoices = Invoice.query.filter(Invoice.id.in_(invoice_ids)).all()
        
        posted_count = 0
        skipped_count = 0
        
        for invoice in invoices:
            if not invoice.is_posted:
                invoice.is_posted = True
                invoice.posted_at = datetime.now()
                invoice.posted_by = posted_by
                posted_count += 1
                
                # تسجيل كل عملية ناجحة
                AuditLog.log_action(
                    user_name=posted_by,
                    action='post',
                    entity_type='invoice',
                    entity_id=invoice.id,
                    entity_number=invoice.invoice_number,
                    details=json.dumps({'batch_operation': True}, ensure_ascii=False),
                    ip_address=request.remote_addr,
                    user_agent=request.headers.get('User-Agent')
                )
            else:
                skipped_count += 1
        
        db.session.commit()
        
        # تسجيل العملية الجماعية
        AuditLog.log_action(
            user_name=posted_by,
            action='post_batch',
            entity_type='invoice',
            entity_id=0,  # batch operation
            details=json.dumps({
                'total_invoices': len(invoice_ids),
                'posted_count': posted_count,
                'skipped_count': skipped_count
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        return jsonify({
            'success': True,
            'message': f'تم ترحيل {posted_count} فاتورة، تم تخطي {skipped_count}',
            'posted_count': posted_count,
            'skipped_count': skipped_count
        }), 200
        
    except Exception as e:
        db.session.rollback()
        posted_by = g.current_user.username if hasattr(g, 'current_user') else 'النظام'
        AuditLog.log_action(
            user_name=posted_by,
            action='post_batch',
            entity_type='invoice',
            entity_id=0,  # batch operation لا يوجد entity_id محدد
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/invoices/unpost/<int:invoice_id>', methods=['POST'])
@require_permission('invoice.unpost')
def unpost_invoice(invoice_id):
    """
    إلغاء ترحيل فاتورة
    
    يتطلب صلاحية: invoice.unpost
    
    ⚠️ تحذير: هذا الإجراء حساس ويجب استخدامه بحذر
    """
    try:
        posted_by = g.current_user.username
        invoice = Invoice.query.get(invoice_id)
        if not invoice:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='invoice',
                entity_id=invoice_id,
                success=False,
                error_message='الفاتورة غير موجودة',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({'success': False, 'message': 'الفاتورة غير موجودة'}), 404
        
        if not invoice.is_posted:
            AuditLog.log_action(
                user_name=request.json.get('posted_by', 'system'),
                action='unpost',
                entity_type='invoice',
                entity_id=invoice_id,
                entity_number=invoice.invoice_number,
                success=False,
                error_message='الفاتورة غير مرحلة أصلاً',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({
                'success': False, 
                'message': 'الفاتورة غير مرحلة أصلاً'
            }), 400
        
        # إلغاء الترحيل
        invoice.is_posted = False
        invoice.posted_at = None
        invoice.posted_by = None
        
        # تسجيل العملية الناجحة
        posted_by = g.current_user.username if hasattr(g, 'current_user') else 'system'
        AuditLog.log_action(
            user_name=posted_by,
            action='unpost',
            entity_type='invoice',
            entity_id=invoice_id,
            entity_number=invoice.invoice_number,
            details=json.dumps({
                'invoice_type': invoice.invoice_type,
                'total_amount': float(invoice.total_amount or 0)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()  # Commit بعد تسجيل الـ Audit Log
        
        return jsonify({
            'success': True,
            'message': 'تم إلغاء ترحيل الفاتورة',
            'invoice': invoice.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=request.json.get('posted_by', 'system'),
            action='unpost',
            entity_type='invoice',
            entity_id=invoice_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# ✅ ترحيل القيود
# ==========================================

@posting_bp.route('/journal-entries/post/<int:entry_id>', methods=['POST'])
@require_permission('journal.post')
def post_journal_entry(entry_id):
    """
    ترحيل قيد يومية
    
    يتطلب صلاحية: journal.post
    """
    try:
        posted_by = g.current_user.username
        
        entry = JournalEntry.query.get(entry_id)
        if not entry:
            return jsonify({'success': False, 'message': 'القيد غير موجود'}), 404
        
        if entry.is_deleted:
            return jsonify({'success': False, 'message': 'القيد محذوف'}), 400
        
        if entry.is_posted:
            return jsonify({
                'success': False, 
                'message': 'القيد مرحل بالفعل'
            }), 400
        
        # التحقق من التوازن قبل الترحيل (النظام يستخدم cash_debit/credit و karat debits/credits)
        total_cash_debit = sum(line.cash_debit or 0 for line in entry.lines if not line.is_deleted)
        total_cash_credit = sum(line.cash_credit or 0 for line in entry.lines if not line.is_deleted)
        
        # التحقق من توازن النقد
        if abs(total_cash_debit - total_cash_credit) > 0.01:  # هامش خطأ صغير
            return jsonify({
                'success': False,
                'message': f'القيد غير متوازن (نقد). مدين: {total_cash_debit}, دائن: {total_cash_credit}'
            }), 400
        
        # التحقق من توازن الذهب لكل عيار
        for karat in ['18k', '21k', '22k', '24k']:
            total_debit = sum(getattr(line, f'debit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
            total_credit = sum(getattr(line, f'credit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
            
            if abs(total_debit - total_credit) > 0.001:  # هامش خطأ أصغر للذهب
                return jsonify({
                    'success': False,
                    'message': f'القيد غير متوازن (عيار {karat}). مدين: {total_debit}, دائن: {total_credit}'
                }), 400
        
        # ترحيل القيد
        entry.is_posted = True
        entry.posted_at = datetime.now()
        entry.posted_by = posted_by
        
        # تسجيل العملية الناجحة
        AuditLog.log_action(
            user_name=posted_by,
            action='post',
            entity_type='journal_entry',
            entity_id=entry_id,
            entity_number=entry.entry_number,
            details=json.dumps({
                'entry_type': entry.entry_type,
                'description': entry.description,
                'total_cash_debit': float(total_cash_debit),
                'total_cash_credit': float(total_cash_credit)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()  # Commit بعد تسجيل الـ Audit Log
        
        return jsonify({
            'success': True,
            'message': 'تم ترحيل القيد بنجاح',
            'entry': entry.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='post',
            entity_type='journal_entry',
            entity_id=entry_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/post-batch', methods=['POST'])
@require_permission('journal.post')
def post_journal_entries_batch():
    """
    ترحيل مجموعة قيود
    
    Body:
    {
        "entry_ids": [1, 2, 3, ...]
    }
    
    يتطلب صلاحية: journal.post
    """
    try:
        posted_by = g.current_user.username
        data = request.get_json()
        entry_ids = data.get('entry_ids', [])
        
        if not entry_ids:
            return jsonify({'success': False, 'message': 'لم يتم تحديد أي قيود'}), 400
        
        entries = JournalEntry.query.filter(
            JournalEntry.id.in_(entry_ids),
            JournalEntry.is_deleted == False
        ).all()
        
        posted_count = 0
        skipped_count = 0
        errors = []
        
        for entry in entries:
            if not entry.is_posted:
                # التحقق من التوازن (النقد)
                total_cash_debit = sum(line.cash_debit or 0 for line in entry.lines if not line.is_deleted)
                total_cash_credit = sum(line.cash_credit or 0 for line in entry.lines if not line.is_deleted)
                
                if abs(total_cash_debit - total_cash_credit) > 0.01:
                    errors.append(f"القيد {entry.entry_number} غير متوازن (نقد)")
                    skipped_count += 1
                    continue
                
                # التحقق من توازن الذهب
                is_balanced = True
                for karat in ['18k', '21k', '22k', '24k']:
                    total_debit = sum(getattr(line, f'debit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
                    total_credit = sum(getattr(line, f'credit_{karat}', 0) or 0 for line in entry.lines if not line.is_deleted)
                    
                    if abs(total_debit - total_credit) > 0.001:
                        errors.append(f"القيد {entry.entry_number} غير متوازن (عيار {karat})")
                        skipped_count += 1
                        is_balanced = False
                        break
                
                if not is_balanced:
                    continue
                
                entry.is_posted = True
                entry.posted_at = datetime.now()
                entry.posted_by = posted_by
                posted_count += 1
                
                # تسجيل كل عملية ناجحة
                AuditLog.log_action(
                    user_name=posted_by,
                    action='post',
                    entity_type='journal_entry',
                    entity_id=entry.id,
                    entity_number=entry.entry_number,
                    details=json.dumps({'batch_operation': True}, ensure_ascii=False),
                    ip_address=request.remote_addr,
                    user_agent=request.headers.get('User-Agent')
                )
            else:
                skipped_count += 1
        
        db.session.commit()
        
        # تسجيل العملية الجماعية
        AuditLog.log_action(
            user_name=posted_by,
            action='post_batch',
            entity_type='journal_entry',
            entity_id=0,  # batch operation
            details=json.dumps({
                'total_entries': len(entry_ids),
                'posted_count': posted_count,
                'skipped_count': skipped_count,
                'errors': errors
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        return jsonify({
            'success': True,
            'message': f'تم ترحيل {posted_count} قيد، تم تخطي {skipped_count}',
            'posted_count': posted_count,
            'skipped_count': skipped_count,
            'errors': errors
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/journal-entries/unpost/<int:entry_id>', methods=['POST'])
@require_permission('journal.unpost')
def unpost_journal_entry(entry_id):
    """
    إلغاء ترحيل قيد
    
    يتطلب صلاحية: journal.unpost
    ⚠️ تحذير: هذا الإجراء حساس ويجب استخدامه بحذر
    """
    try:
        posted_by = g.current_user.username
        entry = JournalEntry.query.get(entry_id)
        
        if not entry:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='journal_entry',
                entity_id=entry_id,
                success=False,
                error_message='القيد غير موجود',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({'success': False, 'message': 'القيد غير موجود'}), 404
        
        if entry.is_deleted:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='journal_entry',
                entity_id=entry_id,
                entity_number=entry.entry_number,
                success=False,
                error_message='القيد محذوف',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({'success': False, 'message': 'القيد محذوف'}), 400
        
        if not entry.is_posted:
            AuditLog.log_action(
                user_name=posted_by,
                action='unpost',
                entity_type='journal_entry',
                entity_id=entry_id,
                entity_number=entry.entry_number,
                success=False,
                error_message='القيد غير مرحل أصلاً',
                ip_address=request.remote_addr,
                user_agent=request.headers.get('User-Agent')
            )
            return jsonify({
                'success': False, 
                'message': 'القيد غير مرحل أصلاً'
            }), 400
        
        # إلغاء الترحيل
        entry.is_posted = False
        entry.posted_at = None
        entry.posted_by = None
        
        # تسجيل العملية الناجحة
        AuditLog.log_action(
            user_name=posted_by,
            action='unpost',
            entity_type='journal_entry',
            entity_id=entry_id,
            entity_number=entry.entry_number,
            details=json.dumps({
                'entry_type': entry.entry_type,
                'description': entry.description
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()  # Commit بعد تسجيل الـ Audit Log
        
        return jsonify({
            'success': True,
            'message': 'تم إلغاء ترحيل القيد',
            'entry': entry.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        posted_by = request.json.get('posted_by', 'system') if request.json else 'system'
        AuditLog.log_action(
            user_name=posted_by,
            action='unpost',
            entity_type='journal_entry',
            entity_id=entry_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# 📊 إحصائيات الترحيل
# ==========================================

@posting_bp.route('/posting/stats', methods=['GET'])
@optional_auth
def get_posting_stats():
    """عرض إحصائيات الترحيل (لا يتطلب صلاحيات)"""
    try:
        stats = {
            'invoices': {
                'total': Invoice.query.count(),
                'posted': Invoice.query.filter_by(is_posted=True).count(),
                'unposted': Invoice.query.filter_by(is_posted=False).count()
            },
            'journal_entries': {
                'total': JournalEntry.query.filter_by(is_deleted=False).count(),
                'posted': JournalEntry.query.filter_by(is_posted=True, is_deleted=False).count(),
                'unposted': JournalEntry.query.filter_by(is_posted=False, is_deleted=False).count()
            }
        }
        
        return jsonify({
            'success': True,
            'stats': stats
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# 📋 سجل التدقيق (Audit Log)
# ==========================================

@posting_bp.route('/audit-logs', methods=['GET'])
@require_permission('audit.view')
def get_audit_logs():
    """
    عرض سجلات التدقيق
    
    يتطلب صلاحية: audit.view
    
    Query Parameters:
    - limit: عدد السجلات (افتراضي 100)
    - user_name: تصفية حسب اسم المستخدم
    - action: تصفية حسب نوع العملية
    - entity_type: تصفية حسب نوع الكيان
    - entity_id: تصفية حسب معرف الكيان
    - success: تصفية حسب النجاح/الفشل (true/false)
    - from_date: من تاريخ (ISO format)
    - to_date: إلى تاريخ (ISO format)
    """
    try:
        # البارامترات
        limit = request.args.get('limit', 100, type=int)
        user_name = request.args.get('user_name')
        action = request.args.get('action')
        entity_type = request.args.get('entity_type')
        entity_id = request.args.get('entity_id', type=int)
        success = request.args.get('success')
        from_date = request.args.get('from_date')
        to_date = request.args.get('to_date')
        
        # بناء الاستعلام
        query = AuditLog.query
        
        if user_name:
            query = query.filter(AuditLog.user_name.like(f'%{user_name}%'))
        
        if action:
            query = query.filter_by(action=action)
        
        if entity_type:
            query = query.filter_by(entity_type=entity_type)
        
        if entity_id:
            query = query.filter_by(entity_id=entity_id)
        
        if success is not None:
            success_bool = success.lower() == 'true'
            query = query.filter_by(success=success_bool)
        
        if from_date:
            try:
                from_dt = datetime.fromisoformat(from_date)
                query = query.filter(AuditLog.timestamp >= from_dt)
            except:
                pass
        
        if to_date:
            try:
                to_dt = datetime.fromisoformat(to_date)
                query = query.filter(AuditLog.timestamp <= to_dt)
            except:
                pass
        
        # الترتيب والحد الأقصى
        logs = query.order_by(AuditLog.timestamp.desc()).limit(limit).all()
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/<int:log_id>', methods=['GET'])
@require_permission('audit.view')
def get_audit_log_detail(log_id):
    """الحصول على تفاصيل سجل تدقيق معين"""
    try:
        log = AuditLog.query.get(log_id)
        if not log:
            return jsonify({'success': False, 'message': 'السجل غير موجود'}), 404
        
        return jsonify({
            'success': True,
            'log': log.to_dict(include_details=True)
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/entity/<entity_type>/<int:entity_id>', methods=['GET'])
@require_permission('audit.view')
def get_audit_logs_by_entity(entity_type, entity_id):
    """الحصول على جميع سجلات التدقيق لكيان معين"""
    try:
        logs = AuditLog.get_logs_by_entity(entity_type, entity_id)
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'entity_type': entity_type,
            'entity_id': entity_id,
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/user/<user_name>', methods=['GET'])
@require_permission('audit.view')
def get_audit_logs_by_user(user_name):
    """الحصول على سجلات مستخدم معين"""
    try:
        limit = request.args.get('limit', 100, type=int)
        logs = AuditLog.get_logs_by_user(user_name, limit=limit)
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'user_name': user_name,
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/failed', methods=['GET'])
@require_permission('audit.view')
def get_failed_audit_logs():
    """الحصول على العمليات الفاشلة"""
    try:
        limit = request.args.get('limit', 50, type=int)
        logs = AuditLog.get_failed_logs(limit=limit)
        
        return jsonify({
            'success': True,
            'count': len(logs),
            'logs': [log.to_dict() for log in logs]
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/audit-logs/stats', methods=['GET'])
@require_permission('audit.view')
def get_audit_stats():
    """إحصائيات سجل التدقيق"""
    try:
        from sqlalchemy import func
        
        # إجمالي السجلات
        total_logs = AuditLog.query.count()
        
        # السجلات الناجحة والفاشلة
        successful = AuditLog.query.filter_by(success=True).count()
        failed = AuditLog.query.filter_by(success=False).count()
        
        # أكثر العمليات تكراراً
        top_actions = db.session.query(
            AuditLog.action,
            func.count(AuditLog.id).label('count')
        ).group_by(AuditLog.action).order_by(func.count(AuditLog.id).desc()).limit(10).all()
        
        # أكثر المستخدمين نشاطاً
        top_users = db.session.query(
            AuditLog.user_name,
            func.count(AuditLog.id).label('count')
        ).group_by(AuditLog.user_name).order_by(func.count(AuditLog.id).desc()).limit(10).all()
        
        # السجلات اليوم
        today = datetime.now().date()
        today_start = datetime.combine(today, datetime.min.time())
        logs_today = AuditLog.query.filter(AuditLog.timestamp >= today_start).count()
        
        stats = {
            'total_logs': total_logs,
            'successful': successful,
            'failed': failed,
            'logs_today': logs_today,
            'top_actions': [{'action': action, 'count': count} for action, count in top_actions],
            'top_users': [{'user_name': user, 'count': count} for user, count in top_users]
        }
        
        return jsonify({
            'success': True,
            'stats': stats
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


# ==========================================
# 📝 نظام الموافقة على السندات (Voucher Approval)
# ==========================================

@posting_bp.route('/vouchers/pending', methods=['GET'])
@require_permission('voucher.view')
def get_pending_vouchers():
    """عرض جميع السندات بانتظار الموافقة"""
    try:
        from models import Voucher
        
        vouchers = Voucher.query.filter_by(
            status='pending'
        ).order_by(Voucher.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(vouchers),
            'vouchers': [v.to_dict() for v in vouchers]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/approved', methods=['GET'])
@require_permission('voucher.view')
def get_approved_vouchers():
    """عرض جميع السندات الموافق عليها"""
    try:
        from models import Voucher
        
        vouchers = Voucher.query.filter_by(
            status='approved'
        ).order_by(Voucher.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(vouchers),
            'vouchers': [v.to_dict() for v in vouchers]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/rejected', methods=['GET'])
@require_permission('voucher.view')
def get_rejected_vouchers():
    """عرض جميع السندات المرفوضة"""
    try:
        from models import Voucher
        
        vouchers = Voucher.query.filter_by(
            status='rejected'
        ).order_by(Voucher.date.desc()).all()
        
        return jsonify({
            'success': True,
            'count': len(vouchers),
            'vouchers': [v.to_dict() for v in vouchers]
        }), 200
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/approve/<int:voucher_id>', methods=['POST'])
@require_permission('voucher.approve')
def approve_voucher(voucher_id):
    """
    الموافقة على سند
    
    يتطلب صلاحية: voucher.approve
    """
    try:
        from models import Voucher
        
        approved_by = g.current_user.username
        
        voucher = Voucher.query.get(voucher_id)
        if not voucher:
            return jsonify({'success': False, 'message': 'السند غير موجود'}), 404
        
        if voucher.status == 'approved':
            return jsonify({
                'success': False,
                'message': 'السند موافق عليه بالفعل'
            }), 400
        
        if voucher.status == 'cancelled':
            return jsonify({
                'success': False,
                'message': 'لا يمكن الموافقة على سند ملغى'
            }), 400
        
        # الموافقة على السند
        voucher.status = 'approved'
        voucher.approved_at = datetime.now()
        voucher.approved_by = approved_by
        
        # تسجيل العملية
        AuditLog.log_action(
            user_name=approved_by,
            action='voucher_approve',
            entity_type='voucher',
            entity_id=voucher_id,
            entity_number=voucher.voucher_number,
            details=json.dumps({
                'voucher_type': voucher.voucher_type,
                'amount_cash': float(voucher.amount_cash or 0),
                'amount_gold': float(voucher.amount_gold or 0),
                'description': voucher.description
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم الموافقة على السند بنجاح',
            'voucher': voucher.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='voucher_approve',
            entity_type='voucher',
            entity_id=voucher_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/reject/<int:voucher_id>', methods=['POST'])
@require_permission('voucher.approve')
def reject_voucher(voucher_id):
    """
    رفض سند
    
    يتطلب صلاحية: voucher.approve
    
    Body:
    {
        "rejection_reason": "سبب الرفض"
    }
    """
    try:
        from models import Voucher
        
        data = request.get_json()
        rejected_by = g.current_user.username
        rejection_reason = data.get('rejection_reason', '')
        
        if not rejection_reason:
            return jsonify({
                'success': False,
                'message': 'يجب تحديد سبب الرفض'
            }), 400
        
        voucher = Voucher.query.get(voucher_id)
        if not voucher:
            return jsonify({'success': False, 'message': 'السند غير موجود'}), 404
        
        if voucher.status == 'rejected':
            return jsonify({
                'success': False,
                'message': 'السند مرفوض بالفعل'
            }), 400
        
        if voucher.status == 'cancelled':
            return jsonify({
                'success': False,
                'message': 'لا يمكن رفض سند ملغى'
            }), 400
        
        # رفض السند
        voucher.status = 'rejected'
        voucher.rejected_at = datetime.now()
        voucher.rejected_by = rejected_by
        voucher.rejection_reason = rejection_reason
        
        # تسجيل العملية
        AuditLog.log_action(
            user_name=rejected_by,
            action='voucher_reject',
            entity_type='voucher',
            entity_id=voucher_id,
            entity_number=voucher.voucher_number,
            details=json.dumps({
                'voucher_type': voucher.voucher_type,
                'rejection_reason': rejection_reason,
                'amount_cash': float(voucher.amount_cash or 0),
                'amount_gold': float(voucher.amount_gold or 0)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم رفض السند',
            'voucher': voucher.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='voucher_reject',
            entity_type='voucher',
            entity_id=voucher_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/approve/batch', methods=['POST'])
@require_permission('voucher.approve')
def approve_vouchers_batch():
    """
    الموافقة على مجموعة سندات دفعة واحدة
    
    Body:
    {
        "voucher_ids": [1, 2, 3, ...]
    }
    """
    try:
        from models import Voucher
        
        data = request.get_json()
        approved_by = g.current_user.username
        voucher_ids = data.get('voucher_ids', [])
        
        if not voucher_ids:
            return jsonify({
                'success': False,
                'message': 'لم يتم تحديد أي سندات'
            }), 400
        
        approved_count = 0
        errors = []
        
        for voucher_id in voucher_ids:
            try:
                voucher = Voucher.query.get(voucher_id)
                if not voucher:
                    errors.append(f'السند {voucher_id} غير موجود')
                    continue
                
                if voucher.status != 'pending':
                    errors.append(f'السند {voucher.voucher_number} ليس بانتظار الموافقة')
                    continue
                
                voucher.status = 'approved'
                voucher.approved_at = datetime.now()
                voucher.approved_by = approved_by
                approved_count += 1
                
            except Exception as e:
                errors.append(f'خطأ في السند {voucher_id}: {str(e)}')
        
        # تسجيل العملية الجماعية
        AuditLog.log_action(
            user_name=approved_by,
            action='batch_voucher_approve',
            entity_type='voucher',
            entity_id=0,
            details=json.dumps({
                'approved_count': approved_count,
                'voucher_ids': voucher_ids,
                'errors': errors
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': f'تم الموافقة على {approved_count} سند',
            'approved_count': approved_count,
            'errors': errors
        }), 200
        
    except Exception as e:
        db.session.rollback()
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/unapprove/<int:voucher_id>', methods=['POST'])
@require_permission('voucher.approve')
def unapprove_voucher(voucher_id):
    """
    إلغاء الموافقة على سند
    
    يتطلب صلاحية: voucher.approve
    """
    try:
        from models import Voucher
        
        unapproved_by = g.current_user.username
        
        voucher = Voucher.query.get(voucher_id)
        if not voucher:
            return jsonify({'success': False, 'message': 'السند غير موجود'}), 404
        
        if voucher.status != 'approved':
            return jsonify({
                'success': False,
                'message': 'السند ليس موافق عليه'
            }), 400
        
        # التحقق من أن السند لم يُستخدم في قيد محاسبي
        if voucher.journal_entry_id:
            return jsonify({
                'success': False,
                'message': 'لا يمكن إلغاء الموافقة لأن السند مرتبط بقيد محاسبي'
            }), 400
        
        # إلغاء الموافقة
        voucher.status = 'pending'
        voucher.approved_at = None
        voucher.approved_by = None
        
        # تسجيل العملية
        AuditLog.log_action(
            user_name=unapproved_by,
            action='voucher_unapprove',
            entity_type='voucher',
            entity_id=voucher_id,
            entity_number=voucher.voucher_number,
            details=json.dumps({
                'voucher_type': voucher.voucher_type,
                'amount_cash': float(voucher.amount_cash or 0),
                'amount_gold': float(voucher.amount_gold or 0)
            }, ensure_ascii=False),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        
        db.session.commit()
        
        return jsonify({
            'success': True,
            'message': 'تم إلغاء الموافقة على السند',
            'voucher': voucher.to_dict()
        }), 200
        
    except Exception as e:
        db.session.rollback()
        AuditLog.log_action(
            user_name=g.current_user.username if g.current_user else 'النظام',
            action='voucher_unapprove',
            entity_type='voucher',
            entity_id=voucher_id,
            success=False,
            error_message=str(e),
            ip_address=request.remote_addr,
            user_agent=request.headers.get('User-Agent')
        )
        return jsonify({'success': False, 'message': str(e)}), 500


@posting_bp.route('/vouchers/stats', methods=['GET'])
@require_permission('voucher.view')
def get_vouchers_stats():
    """إحصائيات السندات"""
    try:
        from models import Voucher
        
        # العدد حسب الحالة
        pending_count = Voucher.query.filter_by(status='pending').count()
        approved_count = Voucher.query.filter_by(status='approved').count()
        rejected_count = Voucher.query.filter_by(status='rejected').count()
        cancelled_count = Voucher.query.filter_by(status='cancelled').count()
        
        # العدد حسب النوع
        receipt_count = Voucher.query.filter_by(voucher_type='receipt').count()
        payment_count = Voucher.query.filter_by(voucher_type='payment').count()
        
        stats = {
            'by_status': {
                'pending': pending_count,
                'approved': approved_count,
                'rejected': rejected_count,
                'cancelled': cancelled_count
            },
            'by_type': {
                'receipt': receipt_count,
                'payment': payment_count
            },
            'total': pending_count + approved_count + rejected_count + cancelled_count
        }
        
        return jsonify({
            'success': True,
            'stats': stats
        }), 200
        
    except Exception as e:
        return jsonify({'success': False, 'message': str(e)}), 500
