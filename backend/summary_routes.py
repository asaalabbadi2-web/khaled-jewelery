from flask import Blueprint, jsonify
from backend.models import db, Invoice, InvoiceItem
from datetime import datetime, date
from sqlalchemy import func

summary_bp = Blueprint('summary_bp', __name__)

@summary_bp.route('/summary/pos', methods=['GET'])
def get_pos_summary():
    """Provides a summary of Point of Sale (POS) data for the current day."""
    today = date.today()

    # 1. Total Sales and Number of Invoices for today
    sales_data = db.session.query(
        func.sum(Invoice.total).label('total_sales'),
        func.count(Invoice.id).label('invoice_count')
    ).filter(
        func.date(Invoice.date) == today,
        Invoice.invoice_type == 'بيع'  # Filter for sales invoices only
    ).first()

    total_sales = sales_data.total_sales or 0
    invoice_count = sales_data.invoice_count or 0

    # 2. Average Sale Amount
    average_sale = total_sales / invoice_count if invoice_count > 0 else 0

    # 3. Top-selling items for today
    top_items = db.session.query(
        InvoiceItem.name,
        func.sum(InvoiceItem.quantity).label('total_quantity')
    ).join(Invoice).filter(
        func.date(Invoice.date) == today,
        Invoice.invoice_type == 'بيع'
    ).group_by(InvoiceItem.name).order_by(func.sum(InvoiceItem.quantity).desc()).limit(5).all()

    summary = {
        'date': today.isoformat(),
        'total_sales': round(total_sales, 2),
        'invoice_count': invoice_count,
        'average_sale': round(average_sale, 2),
        'top_selling_items': [
            {'name': item[0], 'quantity': item[1]} for item in top_items
        ]
    }

    return jsonify(summary)
