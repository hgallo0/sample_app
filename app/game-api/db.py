import os

import sqlalchemy
from google.cloud.sql.connector import Connector, IPTypes
from sqlalchemy.orm import declarative_base, sessionmaker

PROJECT_ID = os.environ["PROJECT_ID"]
REGION = os.environ["REGION"]
INSTANCE_NAME = os.environ.get("INSTANCE_NAME", "rps-postgres")
DB_NAME = os.environ.get("DB_NAME", "rps")
# Service account email with ".gserviceaccount.com" stripped - Cloud SQL's
# IAM auth convention, matches infra/output.tf's db_iam_user output.
DB_IAM_USER = os.environ["DB_IAM_USER"]

INSTANCE_CONNECTION_NAME = f"{PROJECT_ID}:{REGION}:{INSTANCE_NAME}"

connector = Connector()


def _getconn():
    return connector.connect(
        INSTANCE_CONNECTION_NAME,
        "pg8000",
        user=DB_IAM_USER,
        db=DB_NAME,
        enable_iam_auth=True,
        ip_type=IPTypes.PRIVATE,
    )


# No password anywhere - the connector mints short-lived OAuth tokens using
# game-api's own runtime service account identity.
engine = sqlalchemy.create_engine(
    "postgresql+pg8000://", creator=_getconn, pool_pre_ping=True
)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)
Base = declarative_base()


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
