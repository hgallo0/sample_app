import os

os.environ.setdefault("PROJECT_ID", "test-project")
os.environ.setdefault("REGION", "us-central1")
os.environ.setdefault("DB_IAM_USER", "test-iam-user")
os.environ.setdefault("REDIS_HOST", "localhost")
os.environ.setdefault("GAME_ENGINE_URL", "http://game-engine.test")

# db.py builds a real Cloud SQL Connector() at import time. Patch it before
# anything imports db.py, so tests never touch ADC or the network.
from google.cloud.sql import connector as _connector_module  # noqa: E402


class _FakeConnector:
    def __init__(self, *a, **kw):
        pass

    def connect(self, *a, **kw):
        raise RuntimeError("Cloud SQL should never be dialed in unit tests")


_connector_module.Connector = _FakeConnector
