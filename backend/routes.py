# REST API routes for customers, items, invoices
from flask import Blueprint, request, jsonify
from models import db, Customer, Item, Invoice, InvoiceItem
from datetime import datetime

api = Blueprint('api', __name__)

# Customers CRUD
@api.route('/customers', methods=['GET'])
def get_customers():
	customers = Customer.query.all()
	return jsonify([{'id': c.id, 'name': c.name, 'phone': c.phone, 'email': c.email} for c in customers])

@api.route('/customers', methods=['POST'])
def add_customer():
	data = request.json
	customer = Customer(name=data['name'], phone=data.get('phone'), email=data.get('email'))
	db.session.add(customer)
	db.session.commit()
	return jsonify({'id': customer.id}), 201

# Items CRUD
@api.route('/items', methods=['GET'])
def get_items():
	items = Item.query.all()
	return jsonify([{'id': i.id, 'name': i.name, 'description': i.description, 'price': i.price, 'stock': i.stock} for i in items])

@api.route('/items', methods=['POST'])
def add_item():
	data = request.json
	item = Item(name=data['name'], description=data.get('description'), price=data['price'], stock=data.get('stock', 0))
	db.session.add(item)
	db.session.commit()
	return jsonify({'id': item.id}), 201

# Invoices CRUD
@api.route('/invoices', methods=['GET'])
def get_invoices():
	invoices = Invoice.query.all()
	result = []
	for inv in invoices:
		result.append({
			'id': inv.id,
			'customer_id': inv.customer_id,
			'date': inv.date.isoformat(),
			'total': inv.total,
			'items': [
				{
					'item_id': ii.item_id,
					'quantity': ii.quantity,
					'price': ii.price
				} for ii in inv.items
			]
		})
	return jsonify(result)

@api.route('/invoices', methods=['POST'])
def add_invoice():
	data = request.json
	invoice = Invoice(
		customer_id=data['customer_id'],
		date=datetime.fromisoformat(data['date']),
		total=data['total']
	)
	db.session.add(invoice)
	db.session.flush()  # Get invoice.id before commit
	for item in data['items']:
		invoice_item = InvoiceItem(
			invoice_id=invoice.id,
			item_id=item['item_id'],
			quantity=item['quantity'],
			price=item['price']
		)
		db.session.add(invoice_item)
	db.session.commit()
	return jsonify({'id': invoice.id}), 201
