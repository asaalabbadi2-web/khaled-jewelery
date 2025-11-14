#!/usr/bin/env python3
import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from flask import Flask
from backend.models import db
from backend.routes import api
import os
from flask_cors import CORS

app = Flask(__name__)
app.config['SQLALCHEMY_DATABASE_URI'] = os.getenv('DATABASE_URL', f"sqlite:///{os.path.join(os.path.dirname(os.path.abspath(__file__)), 'app.db')}")
app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False

CORS(app)
db.init_app(app)
app.register_blueprint(api, url_prefix='/api')

with app.app_context():
    from backend.models import Voucher
    count = Voucher.query.count()
    print(f'Total vouchers: {count}')

    if count > 0:
        vouchers = Voucher.query.limit(5).all()
        for v in vouchers:
            print(f'ID: {v.id}, Number: {v.voucher_number}, Type: {v.voucher_type}, Status: {v.status}, Date: {v.date}')
    else:
        print('No vouchers found in database')