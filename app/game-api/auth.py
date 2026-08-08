import firebase_admin
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from firebase_admin import auth as firebase_auth

if not firebase_admin._apps:
    firebase_admin.initialize_app()

bearer_scheme = HTTPBearer()


class CurrentUser:
    def __init__(self, uid: str, email: str | None):
        self.uid = uid
        self.email = email


def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(bearer_scheme),
) -> CurrentUser:
    try:
        decoded = firebase_auth.verify_id_token(credentials.credentials)
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or expired token",
        )
    return CurrentUser(uid=decoded["uid"], email=decoded.get("email"))
