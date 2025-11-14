#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
API Routes لإدارة المكاتب (مكاتب بيع وشراء الذهب الخام)
"""

from flask import Blueprint, request, jsonify
from models import (
    db,
    Office,
)

# إنشاء Blueprint
offices_bp = Blueprint('offices', __name__, url_prefix='/api/offices')


@offices_bp.route('', methods=['GET'])
def get_offices():
    """
    الحصول على قائمة المكاتب
    """
    try:
        offices = db.session.query(Office).all()
        return jsonify([office.to_dict() for office in offices]), 200
    except Exception as e:
        print(f"❌ خطأ في جلب المكاتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>', methods=['GET'])
def get_office(office_id):
    """الحصول على تفاصيل مكتب معين"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        return jsonify(office.to_dict()), 200
    
    except Exception as e:
        print(f"❌ خطأ في جلب المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('', methods=['POST'])
def create_office():
    """إنشاء مكتب جديد"""
    try:
        data = request.get_json()
        
        # التحقق من البيانات المطلوبة
        if not data.get('name'):
            return jsonify({'error': 'اسم المكتب مطلوب'}), 400
        
        # توليد كود المكتب
        office_code = "OFF-000001"  # generate_office_code()
        
        # إنشاء المكتب
        office = Office(
            office_code=office_code,
            name=data['name'],
            phone=data.get('phone'),
            email=data.get('email'),
            contact_person=data.get('contact_person'),
            address_line_1=data.get('address_line_1'),
            address_line_2=data.get('address_line_2'),
            city=data.get('city'),
            state=data.get('state'),
            postal_code=data.get('postal_code'),
            country=data.get('country', 'Saudi Arabia'),
            notes=data.get('notes'),
            license_number=data.get('license_number'),
            tax_number=data.get('tax_number'),
            active=data.get('active', True)
        )
        
        # إنشاء حساب محاسبي للمكتب (إذا لم يكن موجوداً)
        if data.get('create_account', True):
            # البحث عن الحساب الأب للمكاتب (يمكن إنشاؤه مسبقاً)
            parent_account = Account.query.filter_by(
                account_number='2120',
                name='مكاتب بيع وشراء الذهب'
            ).first()
            
            if not parent_account:
                # إنشاء الحساب الأب إذا لم يكن موجوداً
                parent_account = Account(
                    account_number='2120',
                    name='مكاتب بيع وشراء الذهب',
                    type='Liability',
                    transaction_type='both',
                    tracks_weight=True,
                    parent_id=None  # يمكن ربطه بحساب الخصوم
                )
                db.session.add(parent_account)
                db.session.flush()
            
            # إنشاء حساب فرعي للمكتب
            # رقم الحساب: 2120 + رقم المكتب (مثال: 2120-000001)
            office_account_number = f"2120-{office_code.split('-')[1]}"
            
            office_account = Account(
                account_number=office_account_number,
                name=f'{office.name} - {office_code}',
                type='Liability',
                transaction_type='both',
                tracks_weight=True,
                parent_id=parent_account.id
            )
            
            db.session.add(office_account)
            db.session.flush()
            
            office.account_id = office_account.id
        
        db.session.add(office)
        db.session.commit()
        
        print(f"✅ تم إنشاء المكتب: {office.office_code} - {office.name}")
        return jsonify(office.to_dict()), 201
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في إنشاء المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>', methods=['PUT'])
def update_office(office_id):
    """تحديث بيانات مكتب"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        data = request.get_json()
        
        # تحديث البيانات
        if 'name' in data:
            office.name = data['name']
            # تحديث اسم الحساب المحاسبي أيضاً
            if office.account:
                office.account.name = f"{data['name']} - {office.office_code}"
        
        if 'phone' in data:
            office.phone = data['phone']
        if 'email' in data:
            office.email = data['email']
        if 'contact_person' in data:
            office.contact_person = data['contact_person']
        if 'address_line_1' in data:
            office.address_line_1 = data['address_line_1']
        if 'address_line_2' in data:
            office.address_line_2 = data['address_line_2']
        if 'city' in data:
            office.city = data['city']
        if 'state' in data:
            office.state = data['state']
        if 'postal_code' in data:
            office.postal_code = data['postal_code']
        if 'country' in data:
            office.country = data['country']
        if 'notes' in data:
            office.notes = data['notes']
        if 'license_number' in data:
            office.license_number = data['license_number']
        if 'tax_number' in data:
            office.tax_number = data['tax_number']
        if 'active' in data:
            office.active = data['active']
        
        db.session.commit()
        
        print(f"✅ تم تحديث المكتب: {office.office_code} - {office.name}")
        return jsonify(office.to_dict()), 200
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في تحديث المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>', methods=['DELETE'])
def delete_office(office_id):
    """حذف مكتب (soft delete)"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        # Soft delete - تعطيل المكتب بدلاً من حذفه
        office.active = False
        db.session.commit()
        
        print(f"✅ تم تعطيل المكتب: {office.office_code} - {office.name}")
        return jsonify({'message': 'تم تعطيل المكتب بنجاح'}), 200
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في حذف المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>/activate', methods=['POST'])
def activate_office(office_id):
    """تفعيل مكتب"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        office.active = True
        db.session.commit()
        
        print(f"✅ تم تفعيل المكتب: {office.office_code} - {office.name}")
        return jsonify(office.to_dict()), 200
    
    except Exception as e:
        db.session.rollback()
        print(f"❌ خطأ في تفعيل المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/<int:office_id>/balance', methods=['GET'])
def get_office_balance(office_id):
    """الحصول على رصيد المكتب"""
    try:
        office = db.session.query(Office).get(office_id)
        if not office:
            return jsonify({'error': 'المكتب غير موجود'}), 404
        
        balance_data = {
            'office_id': office.id,
            'office_code': office.office_code,
            'office_name': office.name,
            'balance_cash': round(office.balance_cash, 2),
            'balance_gold': {
                '18k': round(office.balance_gold_18k, 3),
                '21k': round(office.balance_gold_21k, 3),
                '22k': round(office.balance_gold_22k, 3),
                '24k': round(office.balance_gold_24k, 3),
                'total': round(
                    office.balance_gold_18k + office.balance_gold_21k +
                    office.balance_gold_22k + office.balance_gold_24k, 3
                )
            },
            'statistics': {
                'total_reservations': office.total_reservations,
                'total_weight_purchased': round(office.total_weight_purchased, 3),
                'total_amount_paid': round(office.total_amount_paid, 2)
            }
        }
        
        return jsonify(balance_data), 200
    
    except Exception as e:
        print(f"❌ خطأ في جلب رصيد المكتب: {e}")
        return jsonify({'error': str(e)}), 500


@offices_bp.route('/statistics', methods=['GET'])
def get_offices_statistics():
    """إحصائيات عامة عن المكاتب"""
    try:
        total_offices = db.session.query(Office).count()
        active_offices = db.session.query(Office).filter_by(active=True).count()
        inactive_offices = total_offices - active_offices
        
        total_reservations = db.session.query(
            db.func.sum(Office.total_reservations)
        ).scalar() or 0
        
        total_weight = db.session.query(
            db.func.sum(Office.total_weight_purchased)
        ).scalar() or 0
        
        total_paid = db.session.query(
            db.func.sum(Office.total_amount_paid)
        ).scalar() or 0
        
        statistics = {
            'total_offices': total_offices,
            'active_offices': active_offices,
            'inactive_offices': inactive_offices,
            'total_reservations': int(total_reservations),
            'total_weight_purchased': round(float(total_weight), 3),
            'total_amount_paid': round(float(total_paid), 2)
        }
        
        return jsonify(statistics), 200
    
    except Exception as e:
        print(f"❌ خطأ في جلب إحصائيات المكاتب: {e}")
        return jsonify({'error': str(e)}), 500
