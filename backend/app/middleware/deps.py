# Auth dependency — the FastAPI equivalent of Express auth middleware.
# Usage in a route:  user = Depends(get_current_user)
from datetime import datetime

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from app.core.security import decode_token
from app.database.session import get_db
from app.models.models import User

bearer = HTTPBearer(auto_error=False)


def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(bearer),
    db: Session = Depends(get_db),
) -> User:
    if credentials is None:
        raise HTTPException(401, detail="Authentication token missing.")
    payload = decode_token(credentials.credentials)
    if not payload:
        raise HTTPException(401, detail="Invalid or expired token.")
    user = db.get(User, payload.get("id"))
    if not user or not user.is_active:
        raise HTTPException(401, detail="Account not found or deactivated.")

    # Cheap presence signal: any authenticated call counts as "active".
    # Powers "Online now" / "Last seen X minutes ago" in Chat.
    # Throttled to ~1 write/30s per user so this doesn't add a DB write
    # to every single API call.
    now = datetime.now()
    if not user.last_seen_at or (now - user.last_seen_at).total_seconds() > 30:
        user.last_seen_at = now
        db.commit()

    return user
