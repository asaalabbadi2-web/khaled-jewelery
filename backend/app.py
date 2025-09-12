# Flask app setup, database connection, and register routes
from flask import Flask
from models import db
from routes import api

def create_app():
	app = Flask(__name__)
	app.config['SQLALCHEMY_DATABASE_URI'] = 'sqlite:///pos.db'  # يمكنك التعديل لاحقًا لقاعدة بيانات أخرى
	app.config['SQLALCHEMY_TRACK_MODIFICATIONS'] = False
	db.init_app(app)
	app.register_blueprint(api)
	return app

if __name__ == "__main__":
	app = create_app()
	with app.app_context():
		db.create_all()
	app.run(debug=True)
