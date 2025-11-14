import sys
import os

# Add the project root to the Python path
sys.path.insert(0, os.path.realpath(os.path.join(os.path.dirname(__file__), '..')))

from backend.app import app, db

with app.app_context():
    print("Creating all database tables...")
    db.create_all()
    print("Database tables created.")
