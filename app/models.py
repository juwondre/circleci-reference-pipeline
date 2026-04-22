from datetime import UTC, datetime

from sqlalchemy import Column, DateTime, Integer, String

from app.db import Base


def _utcnow() -> datetime:
    return datetime.now(UTC)


class Item(Base):
    __tablename__ = "items"

    id = Column(Integer, primary_key=True)
    name = Column(String(120), nullable=False)
    created_at = Column(DateTime(timezone=True), nullable=False, default=_utcnow)

    def to_dict(self) -> dict:
        return {
            "id": self.id,
            "name": self.name,
            "created_at": self.created_at.isoformat(),
        }
