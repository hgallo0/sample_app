import os
from typing import Literal

import google.auth.transport.requests
import google.oauth2.id_token
import httpx
from auth import CurrentUser, get_current_user
from cache import record_win, top_leaderboard
from db import get_db
from fastapi import APIRouter, Depends
from models import GameResult, User
from pydantic import BaseModel
from sqlalchemy.orm import Session

router = APIRouter()

GAME_ENGINE_URL = os.environ["GAME_ENGINE_URL"]


class MoveRequest(BaseModel):
    move: Literal["rock", "paper", "scissors"]


def _get_or_create_user(db: Session, current: CurrentUser) -> User:
    user = db.query(User).filter(User.firebase_uid == current.uid).first()
    if user is None:
        user = User(firebase_uid=current.uid, email=current.email)
        db.add(user)
        db.commit()
        db.refresh(user)
    return user


def _call_game_engine(move: str) -> dict:
    auth_req = google.auth.transport.requests.Request()
    id_token = google.oauth2.id_token.fetch_id_token(auth_req, GAME_ENGINE_URL)
    resp = httpx.post(
        f"{GAME_ENGINE_URL}/play",
        json={"move": move},
        headers={"Authorization": f"Bearer {id_token}"},
        timeout=5.0,
    )
    resp.raise_for_status()
    return resp.json()


@router.post("/move")
def submit_move(
    payload: MoveRequest,
    current: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    user = _get_or_create_user(db, current)
    outcome = _call_game_engine(payload.move)

    game = GameResult(
        user_id=user.id,
        player_move=outcome["player_move"],
        computer_move=outcome["computer_move"],
        result=outcome["result"],
    )
    db.add(game)
    db.commit()

    if outcome["result"] == "win":
        record_win(current.uid)

    return outcome


@router.get("/history")
def get_history(
    current: CurrentUser = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    user = _get_or_create_user(db, current)
    games = (
        db.query(GameResult)
        .filter(GameResult.user_id == user.id)
        .order_by(GameResult.created_at.desc())
        .limit(50)
        .all()
    )
    return [
        {
            "player_move": g.player_move,
            "computer_move": g.computer_move,
            "result": g.result,
            "created_at": g.created_at.isoformat(),
        }
        for g in games
    ]


@router.get("/leaderboard")
def get_leaderboard():
    entries = top_leaderboard()
    return [{"user": uid, "wins": int(score)} for uid, score in entries]
