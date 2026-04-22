import os

from flask import Flask, jsonify, request
from sqlalchemy import select, text

from app.db import SessionLocal, engine
from app.models import Item


def create_app() -> Flask:
    app = Flask(__name__)

    @app.get("/healthz")
    def healthz():
        return jsonify(status="ok", build=os.environ.get("BUILD_SHA", "dev"))

    @app.get("/readyz")
    def readyz():
        with engine.connect() as conn:
            conn.execute(text("SELECT 1"))
        return jsonify(status="ready")

    @app.get("/items")
    def list_items():
        with SessionLocal() as s:
            rows = s.execute(select(Item).order_by(Item.id)).scalars().all()
            return jsonify([r.to_dict() for r in rows])

    @app.post("/items")
    def create_item():
        payload = request.get_json(force=True, silent=True) or {}
        name = (payload.get("name") or "").strip()
        if not name:
            return jsonify(error="name is required"), 400
        with SessionLocal() as s:
            item = Item(name=name)
            s.add(item)
            s.commit()
            s.refresh(item)
            return jsonify(item.to_dict()), 201

    return app
