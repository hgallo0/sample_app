from db import Base
from sqlalchemy import Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import relationship
from sqlalchemy.sql import func


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True)
    firebase_uid = Column(String, unique=True, nullable=False, index=True)
    email = Column(String, nullable=True)
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    games = relationship("GameResult", back_populates="user")


class GameResult(Base):
    __tablename__ = "game_results"

    id = Column(Integer, primary_key=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    player_move = Column(String, nullable=False)
    computer_move = Column(String, nullable=False)
    result = Column(String, nullable=False)  # win / lose / tie
    created_at = Column(DateTime(timezone=True), server_default=func.now())

    user = relationship("User", back_populates="games")
