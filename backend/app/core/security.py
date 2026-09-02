# JWT create/verify — same claims as the old Node backend
# (id, phone, role, name) so tokens stay interchangeable.
from datetime import datetime, timedelta, timezone

import bcrypt
from jose import JWTError, jwt

from app.core.config import settings

# Using the `bcrypt` library directly rather than passlib's
# CryptContext — passlib's bcrypt backend-detection code assumes an
# API (`bcrypt.__about__`) that bcrypt>=4.1 removed, which throws on
# every single hash/verify call with newer bcrypt versions. Calling
# bcrypt directly sidesteps that incompatibility entirely.
_BCRYPT_MAX_BYTES = 72  # bcrypt's own hard limit


def hash_password(raw: str) -> str:
    pw = raw.encode("utf-8")[:_BCRYPT_MAX_BYTES]
    return bcrypt.hashpw(pw, bcrypt.gensalt()).decode("utf-8")


def verify_password(raw: str, hashed: str | None) -> bool:
    if not hashed:
        return False
    try:
        pw = raw.encode("utf-8")[:_BCRYPT_MAX_BYTES]
        return bcrypt.checkpw(pw, hashed.encode("utf-8"))
    except Exception:
        return False


def create_access_token(user: dict) -> str:
    payload = {
        "id": user["id"],
        "phone": user["phone"],
        "role": user.get("role", "customer"),
        "name": user.get("name", ""),
        "exp": datetime.now(timezone.utc)
        + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES),
    }
    return jwt.encode(payload, settings.JWT_SECRET, algorithm=settings.JWT_ALGORITHM)


def decode_token(token: str) -> dict | None:
    try:
        return jwt.decode(token, settings.JWT_SECRET, algorithms=[settings.JWT_ALGORITHM])
    except JWTError:
        return None
