#!/usr/bin/env python3
"""
Database migration script to add the Office table.

This script initializes the Office table with the proper schema:
- office_code: Unique code (OFF-XXXXXX format)
- Basic info: name, contact, address, license, tax
- Balance tracking: cash and gold by karat
- Statistics: transactions, total value, last transaction
- Account linking: Automatically creates linked account in chart (2120-XXXXXX)
- Soft delete support: is_active flag

Usage:
    cd backend
    source venv/bin/activate
    python init_offices_table.py
"""

import sys
import os

# Add the project root to the Python path
sys.path.insert(0, os.path.realpath(os.path.join(os.path.dirname(__file__), '..')))

from backend.app import app, db
from backend.models import Office, Account
from backend.office_code_generator import generate_office_code
from datetime import datetime

def init_offices_table():
    """Initialize the Office table and create sample office if needed."""
    try:
        # Create tables if they don't exist
        db.create_all()
        print("✅ Database tables created/verified")
        
        # Check if we already have offices
        existing_count = Office.query.count()
        if existing_count > 0:
            print(f"ℹ️  Found {existing_count} existing office(s)")
            return
        
        # Create a sample office for testing
        print("\n📝 Creating sample office...")
        
        # Check if account already exists
        account_number = "2120-000001"
        existing_account = Account.query.filter_by(account_number=account_number).first()
        
        if not existing_account:
            # Create linked account in chart of accounts
            account = Account(
                account_number=account_number,
                name="مكتب الذهب الرئيسي - Main Gold Office",
                type="liability",  # Current Liabilities
                transaction_type="both",
                tracks_weight=True
            )
            db.session.add(account)
            db.session.flush()
            account_id = account.id
            print(f"✅ Created account: {account_number}")
        else:
            account_id = existing_account.id
            print(f"ℹ️  Using existing account: {account_number}")
        
        # Create sample office
        office = Office(
            office_code="OFF-000001",  # Manually set first office code
            name="مكتب الذهب الرئيسي",
            phone="0123456789",
            email="main@goldoffice.com",
            contact_person="محمد أحمد",
            address_line_1="شارع الذهب",
            city="الرياض",
            country="السعودية",
            license_number="LIC-001",
            tax_number="TAX-001",
            notes="المكتب الرئيسي للتعاملات",
            account_id=account_id,
            active=True,
            # Initialize balances
            balance_cash=0.0,
            balance_gold_24k=0.0,
            balance_gold_22k=0.0,
            balance_gold_21k=0.0,
            balance_gold_18k=0.0,
            # Initialize statistics
            total_reservations=0,
            total_weight_purchased=0.0,
            total_amount_paid=0.0
        )
        
        db.session.add(office)
        db.session.commit()
        
        print(f"✅ Created sample office: {office.office_code} - {office.name}")
        print(f"   📞 Phone: {office.phone}")
        print(f"   📧 Email: {office.email}")
        print(f"   🏦 Account: {account_number}")
        print(f"   💰 Cash Balance: {office.balance_cash}")
        print(f"   🥇 Gold Balance (21k): {office.balance_gold_21k}g")
        
        print("\n✅ Office table initialized successfully!")
        
    except Exception as e:
        db.session.rollback()
        print(f"❌ Error initializing offices table: {str(e)}")
        raise

if __name__ == '__main__':
    print("=" * 60)
    print("🏢 Initializing Office Table")
    print("=" * 60)
    with app.app_context():
        init_offices_table()
    print("=" * 60)
