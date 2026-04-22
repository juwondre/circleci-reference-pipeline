import os

from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker


def database_url() -> str:
    return os.environ.get(
        "DATABASE_URL",
        "postgresql+psycopg://app:app@localhost:5432/appdb",
    )


engine = create_engine(database_url(), pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
Base = declarative_base()
