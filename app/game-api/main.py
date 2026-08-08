from db import Base, engine
from fastapi import FastAPI
from game import router as game_router

Base.metadata.create_all(bind=engine)

app = FastAPI(title="RPS game-api")
app.include_router(game_router, prefix="/api")


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
