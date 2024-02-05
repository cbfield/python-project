import logging.config
from json import load as json_load
from os import urandom, environ
from pathlib import Path

from flask import Flask

from src.api import blueprints as api_blueprints
from src.web import blueprints as web_blueprints

app = Flask(__name__)
app.config['SECRET_KEY'] = urandom(12)

with open(Path(__file__).resolve().parent / "logging_config" / "config.json") as f:
    config = json_load(f)
logging.config.dictConfig(config)

for blueprint in web_blueprints:
    app.register_blueprint(blueprint)

for blueprint in api_blueprints:
    app.register_blueprint(blueprint, url_prefix="/api/v1/")
