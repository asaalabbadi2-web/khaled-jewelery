# SQLAlchemy models for Customer, Item, Invoice, InvoiceItem
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()

class Customer(db.Model):
	id = db.Column(db.Integer, primary_key=True)
	name = db.Column(db.String(100), nullable=False)
	phone = db.Column(db.String(20))
	email = db.Column(db.String(120))
	invoices = db.relationship('Invoice', backref='customer', lazy=True)

class Item(db.Model):
	id = db.Column(db.Integer, primary_key=True)
	name = db.Column(db.String(100), nullable=False)
	description = db.Column(db.String(200))
	price = db.Column(db.Float, nullable=False)
	stock = db.Column(db.Integer, default=0)
	invoice_items = db.relationship('InvoiceItem', backref='item', lazy=True)

class Invoice(db.Model):
	id = db.Column(db.Integer, primary_key=True)
	customer_id = db.Column(db.Integer, db.ForeignKey('customer.id'), nullable=False)
	date = db.Column(db.DateTime, nullable=False)
	total = db.Column(db.Float, nullable=False)
	items = db.relationship('InvoiceItem', backref='invoice', lazy=True)

class InvoiceItem(db.Model):
	id = db.Column(db.Integer, primary_key=True)
	invoice_id = db.Column(db.Integer, db.ForeignKey('invoice.id'), nullable=False)
	item_id = db.Column(db.Integer, db.ForeignKey('item.id'), nullable=False)
	quantity = db.Column(db.Integer, nullable=False)
	price = db.Column(db.Float, nullable=False)
