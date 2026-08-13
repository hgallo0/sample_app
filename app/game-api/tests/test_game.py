from auth import CurrentUser, get_current_user
from db import Base, get_db
from fastapi import FastAPI
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

import cache
import game

engine = create_engine("sqlite:///:memory:", connect_args={"check_same_thread": False})
TestSession = sessionmaker(bind=engine, autoflush=False, autocommit=False)
Base.metadata.create_all(engine)


def override_get_db():
    db = TestSession()
    try:
        yield db
    finally:
        db.close()


def override_get_current_user():
    return CurrentUser(uid="user-123", email="user@example.com")


app = FastAPI()
app.include_router(game.router, prefix="/api")
app.dependency_overrides[get_db] = override_get_db
app.dependency_overrides[get_current_user] = override_get_current_user

client = TestClient(app)


class FakeRedis:
    def __init__(self):
        self.scores: dict[str, float] = {}

    def zincrby(self, key, amount, member):
        self.scores[member] = self.scores.get(member, 0) + amount

    def zrevrange(self, key, start, end, withscores=False):
        ranked = sorted(self.scores.items(), key=lambda kv: kv[1], reverse=True)
        return ranked[start : end + 1]


def test_move_win(monkeypatch):
    monkeypatch.setattr(cache, "redis_client", FakeRedis())
    monkeypatch.setattr(
        game,
        "_call_game_engine",
        lambda move: {"player_move": "rock", "computer_move": "scissors", "result": "win"},
    )

    resp = client.post("/api/move", json={"move": "rock"})

    assert resp.status_code == 200
    assert resp.json() == {"player_move": "rock", "computer_move": "scissors", "result": "win"}


def test_move_lose_does_not_record_win(monkeypatch):
    fake_redis = FakeRedis()
    monkeypatch.setattr(cache, "redis_client", fake_redis)
    monkeypatch.setattr(
        game,
        "_call_game_engine",
        lambda move: {"player_move": "rock", "computer_move": "paper", "result": "lose"},
    )

    resp = client.post("/api/move", json={"move": "rock"})

    assert resp.status_code == 200
    assert fake_redis.scores == {}


def test_move_rejects_invalid_move():
    resp = client.post("/api/move", json={"move": "lizard"})
    assert resp.status_code == 422


def test_history_returns_only_current_users_games(monkeypatch):
    monkeypatch.setattr(cache, "redis_client", FakeRedis())
    monkeypatch.setattr(
        game,
        "_call_game_engine",
        lambda move: {"player_move": "paper", "computer_move": "rock", "result": "win"},
    )
    client.post("/api/move", json={"move": "paper"})

    resp = client.get("/api/history")

    assert resp.status_code == 200
    body = resp.json()
    assert len(body) >= 1
    assert body[0]["result"] == "win"


def test_leaderboard_reflects_recorded_wins(monkeypatch):
    fake_redis = FakeRedis()
    monkeypatch.setattr(cache, "redis_client", fake_redis)
    fake_redis.zincrby(cache.LEADERBOARD_KEY, 1, "user-123")
    fake_redis.zincrby(cache.LEADERBOARD_KEY, 3, "user-456")

    resp = client.get("/api/leaderboard")

    assert resp.status_code == 200
    assert resp.json() == [
        {"user": "user-456", "wins": 3},
        {"user": "user-123", "wins": 1},
    ]
