import os

import redis

REDIS_HOST = os.environ["REDIS_HOST"]
REDIS_PORT = int(os.environ.get("REDIS_PORT", 6379))
LEADERBOARD_KEY = "leaderboard:wins"

redis_client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)


def record_win(user_key: str) -> None:
    redis_client.zincrby(LEADERBOARD_KEY, 1, user_key)


def top_leaderboard(limit: int = 10):
    return redis_client.zrevrange(LEADERBOARD_KEY, 0, limit - 1, withscores=True)
