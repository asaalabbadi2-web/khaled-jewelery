#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""API Routes لإدارة فروع المعرض/المحل."""

from flask import Blueprint, request, jsonify
from auth_decorators import require_permission

from models import db, Branch

branches_bp = Blueprint('branches', __name__, url_prefix='/api/branches')


@branches_bp.route('', methods=['GET'])
def get_branches():
    """الحصول على قائمة الفروع."""
    try:
        active_param = request.args.get('active')
        query = db.session.query(Branch)
        if active_param is not None:
            normalized = str(active_param).strip().lower()
            if normalized in ('1', 'true', 'yes', 'active'):
                query = query.filter(Branch.active.is_(True))
            elif normalized in ('0', 'false', 'no', 'inactive'):
                query = query.filter(Branch.active.is_(False))

        branches = query.order_by(Branch.id.asc()).all()
        return jsonify([b.to_dict() for b in branches]), 200
    except Exception as exc:
        print(f"❌ خطأ في جلب الفروع: {exc}")
        return jsonify({'error': str(exc)}), 500


@branches_bp.route('/<int:branch_id>', methods=['GET'])
def get_branch(branch_id: int):
    """الحصول على تفاصيل فرع معين."""
    try:
        branch = db.session.query(Branch).get(branch_id)
        if not branch:
            return jsonify({'error': 'الفرع غير موجود'}), 404
        return jsonify(branch.to_dict()), 200
    except Exception as exc:
        print(f"❌ خطأ في جلب الفرع: {exc}")
        return jsonify({'error': str(exc)}), 500


@branches_bp.route('', methods=['POST'])
def create_branch():
    """إنشاء فرع جديد."""
    try:
        data = request.get_json() or {}
        if not data.get('name'):
            return jsonify({'error': 'اسم الفرع مطلوب'}), 400

        from code_generator import generate_branch_code

        requested_code = (data.get('branch_code') or '').strip()
        if requested_code:
            existing = db.session.query(Branch).filter(Branch.branch_code == requested_code).first()
            if existing:
                return jsonify({'error': 'رمز الفرع مستخدم مسبقاً'}), 400

        branch = Branch(
            branch_code=requested_code or generate_branch_code(),
            name=data['name'],
            active=bool(data.get('active', True)),
        )
        db.session.add(branch)
        db.session.commit()
        return jsonify(branch.to_dict()), 201
    except Exception as exc:
        db.session.rollback()
        print(f"❌ خطأ في إنشاء الفرع: {exc}")
        return jsonify({'error': str(exc)}), 500


@branches_bp.route('/<int:branch_id>', methods=['PUT'])
@require_permission('business.setup')
def update_branch(branch_id: int):
    """تحديث بيانات فرع."""
    try:
        branch = db.session.query(Branch).get(branch_id)
        if not branch:
            return jsonify({'error': 'الفرع غير موجود'}), 404

        data = request.get_json() or {}
        if 'name' in data:
            branch.name = data['name']
        if 'branch_code' in data:
            requested_code = (data.get('branch_code') or '').strip()
            if not requested_code:
                return jsonify({'error': 'رمز الفرع غير صالح'}), 400
            existing = (
                db.session.query(Branch)
                .filter(Branch.branch_code == requested_code)
                .filter(Branch.id != branch.id)
                .first()
            )
            if existing:
                return jsonify({'error': 'رمز الفرع مستخدم مسبقاً'}), 400
            branch.branch_code = requested_code
        if 'active' in data:
            branch.active = bool(data['active'])

        db.session.commit()
        return jsonify(branch.to_dict()), 200
    except Exception as exc:
        db.session.rollback()
        print(f"❌ خطأ في تحديث الفرع: {exc}")
        return jsonify({'error': str(exc)}), 500


@branches_bp.route('/<int:branch_id>', methods=['DELETE'])
@require_permission('business.setup')
def delete_branch(branch_id: int):
    """حذف فرع (soft delete: تعطيل)."""
    try:
        branch = db.session.query(Branch).get(branch_id)
        if not branch:
            return jsonify({'error': 'الفرع غير موجود'}), 404

        branch.active = False
        db.session.commit()
        return jsonify({'message': 'تم تعطيل الفرع بنجاح'}), 200
    except Exception as exc:
        db.session.rollback()
        print(f"❌ خطأ في تعطيل الفرع: {exc}")
        return jsonify({'error': str(exc)}), 500


@branches_bp.route('/<int:branch_id>/activate', methods=['POST'])
@require_permission('business.setup')
def activate_branch(branch_id: int):
    """تفعيل فرع."""
    try:
        branch = db.session.query(Branch).get(branch_id)
        if not branch:
            return jsonify({'error': 'الفرع غير موجود'}), 404

        branch.active = True
        db.session.commit()
        return jsonify(branch.to_dict()), 200
    except Exception as exc:
        db.session.rollback()
        print(f"❌ خطأ في تفعيل الفرع: {exc}")
        return jsonify({'error': str(exc)}), 500
