import os

from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base, sessionmaker


def database_url() -> str:
    # Default targets the test/dev Postgres (CI sidecar or local docker
    # container). Production overrides DATABASE_URL from a secrets manager;
    # the hardcoded app:app here is a placeholder, not a real credential.
    return os.environ.get(
        "DATABASE_URL",
        "postgresql+psycopg://app:app@localhost:5432/appdb",
    )


engine = create_engine(database_url(), pool_pre_ping=True, future=True)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)
Base = declarative_base()
