"""Add voucher_auto_post setting

This migration adds a new setting to control voucher workflow:
- voucher_auto_post = False (default): Requires approval before posting
- voucher_auto_post = True: Auto-posts journal entry on creation

Revision ID: add_voucher_auto_post
Revises: previous_revision
Create Date: 2025-01-22
"""

# To apply this migration:
# cd backend
# source venv/bin/activate
# python3 migration_add_voucher_auto_post.py

if __name__ == '__main__':
    from app import app, db
    from models import Settings

    with app.app_context():
        # Add column if not exists
        try:
            db.session.execute(db.text('ALTER TABLE settings ADD COLUMN voucher_auto_post BOOLEAN DEFAULT 0'))
            db.session.commit()
            print("✅ Column added successfully")
        except Exception as e:
            if 'duplicate column name' in str(e).lower():
                print("ℹ️ Column already exists")
            else:
                print(f"❌ Error: {e}")
                db.session.rollback()
        
        # Update existing settings record to ensure it has the field
        settings = Settings.query.first()
        if settings:
            # Check if the attribute exists by trying to access it
            try:
                current_value = settings.voucher_auto_post
                print(f"ℹ️ Current voucher_auto_post value: {current_value}")
            except AttributeError:
                print("⚠️ Attribute not accessible yet, may need to restart app")
            
            print("✅ Migration complete")
        else:
            print("⚠️ No settings record found - will be created on first settings update")

