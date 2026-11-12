# ─────────────────────────────────────────────
# app/core/config.py — central settings
#
# DATABASE_URL and FRONTEND_URL come from env_config.py's LOCAL/
# ONLINE switch UNCONDITIONALLY — deliberately NOT overridable via
# .env, even though the rest of this class still reads .env for
# genuine secrets (JWT_SECRET, Cloudinary keys). This is intentional:
# an early version of this project had a leftover .env file with a
# hardcoded MySQL DATABASE_URL that silently overrode env_config.py's
# switch, which is exactly the kind of confusing, hard-to-spot bug
# the whole point of "one single switch file" was meant to prevent.
# If you need a different database per machine, edit env_config.py
# itself — don't reach for .env for this specific value.
#
# Since Oct 2026: in ONLINE mode env_config.py takes the URL from the
# real DATABASE_URL *environment variable* (Render → Environment), so
# the password no longer has to sit in source. A .env file still
# cannot override it — only the actual process environment can.
# ─────────────────────────────────────────────
from pydantic_settings import BaseSettings, SettingsConfigDict

from app.core.env_config import DATABASE_URL as _DATABASE_URL
from app.core.env_config import FRONTEND_URL as _FRONTEND_URL


class Settings(BaseSettings):
    # SQLAlchemy URL form: postgresql+psycopg2://user:pass@host:port/db
    # Not a "default" — genuinely fixed to env_config.py's value, see
    # note above. (Pydantic still requires a field here; it's just
    # never actually read from .env for this one.)
    DATABASE_URL: str = _DATABASE_URL

    JWT_SECRET: str = "change_me"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 60 * 24 * 30  # 30 days

    # bcrypt work factor for NEW hashes (and for the one-time re-hash at
    # login when a stored hash differs). 12 = unchanged default. Each -1
    # halves the verify time; 10 is the OWASP minimum — do not go lower.
    # Only lower it if the login timing log shows hash time dominating
    # (likely on a CPU-throttled free instance).
    BCRYPT_ROUNDS: int = 12

    APP_NAME: str = "GMS API"
    ENV: str = "development"
    FRONTEND_URL: str = _FRONTEND_URL

    CLOUDINARY_CLOUD_NAME: str = ""
    CLOUDINARY_API_KEY: str = ""
    CLOUDINARY_API_SECRET: str = ""

    # Supabase Storage (avatars/media in ONLINE mode) — genuine secrets,
    # always from .env / Render's Environment Variables UI, NEVER
    # hardcoded here or in env_config.py. The service-role key in
    # particular must only ever exist on the backend — it has full
    # storage write/delete access and should never reach the Flutter
    # app or any client-side code.
    SUPABASE_URL: str = ""
    SUPABASE_SERVICE_ROLE_KEY: str = ""
    SUPABASE_BUCKET: str = "gms-media"

    GOOGLE_APPLICATION_CREDENTIALS: str = "./secrets/firebase-service-account.json"

    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    def model_post_init(self, __context) -> None:
        # Re-assert AFTER .env loading — this is what actually makes
        # these two fields un-overridable, since pydantic-settings
        # applies .env values before this hook runs.
        object.__setattr__(self, "DATABASE_URL", _DATABASE_URL)
        object.__setattr__(self, "FRONTEND_URL", _FRONTEND_URL)


settings = Settings()
