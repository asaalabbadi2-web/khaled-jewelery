#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""اختبارات التكويد الفوري داخل فاتورة الشراء."""

import unittest

from flask import Flask

from models import db, Item
from routes import create_item_from_invoice_payload, InlineItemCreationError

import pytest

@pytest.fixture(autouse=True)
def _behind_the_fence(db_fence):
    """Its commits stay in the test (TEST-003): brought under tests/ from the
    root, where the gate never ran it and what it wrote stayed in the run's
    database."""
    yield



class InlineItemCreationTestCase(unittest.TestCase):
    def setUp(self):
        self.app = Flask(__name__)
        self.app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite://'
        self.app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
        db.init_app(self.app)
        self.ctx = self.app.app_context()
        self.ctx.push()
        db.create_all()

    def tearDown(self):
        db.session.remove()
        db.drop_all()
        self.ctx.pop()

    def test_inline_item_creation_generates_codes(self):
        payload = {
            'name': 'سوار شراء تجريبي',
            'karat': 21,
            'weight': 12.345,
            'manufacturing_wage_per_gram': 8.5,
            'has_stones': True,
            'stones_weight': 0.35,
            'stones_value': 150.0,
            'description': 'تم إدخاله داخل فاتورة المورد',
        }

        item = create_item_from_invoice_payload(payload)

        self.assertIsNotNone(item.id)
        self.assertEqual(Item.query.count(), 1)
        self.assertEqual(item.name, 'سوار شراء تجريبي')
        self.assertEqual(item.karat, '21')
        self.assertAlmostEqual(item.weight, 12.345, places=3)
        self.assertAlmostEqual(item.manufacturing_wage_per_gram, 8.5)
        self.assertTrue(item.has_stones)
        self.assertAlmostEqual(item.stones_weight, 0.35)
        self.assertAlmostEqual(item.stones_value, 150.0)
        self.assertNotEqual(item.item_code, '')
        self.assertNotEqual(item.barcode, '')

    def test_duplicate_manual_code_is_rejected(self):
        base_payload = {
            'name': 'قطعة ذهب',
            'karat': 18,
            'weight': 5.5,
            'manufacturing_wage_per_gram': 6.0,
            'item_code': 'I-555555',
            'barcode': 'B-TEST-1',
        }

        create_item_from_invoice_payload(base_payload)

        with self.assertRaises(InlineItemCreationError):
            create_item_from_invoice_payload({
                **base_payload,
                'barcode': 'B-TEST-2',
            })


if __name__ == '__main__':
    unittest.main()
