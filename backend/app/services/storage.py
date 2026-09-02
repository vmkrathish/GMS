# ─────────────────────────────────────────────
# app/services/storage.py — media storage abstraction
#
# ONE place that decides where an uploaded file actually lives:
#   LOCAL mode  (env_config.IS_ONLINE = False) → local disk, under
#               backend/app/static/avatars/, served at /static/...
#   ONLINE mode (env_config.IS_ONLINE = True)  → Supabase Storage,
#               bucket SUPABASE_BUCKET (default "gms-media"),
#               under avatars/, returns the public URL.
#
# Callers (routers) never touch disk or Supabase directly — they
# call save_avatar()/delete_avatar() and get back exactly what
# users.avatar_url should be set to, same shape either way: a
# string the frontend can hand straight to
# ApiConfig.resolveMediaUrl() unchanged (that function already
# passes any http(s):// URL through as-is and only prefixes bare
# relative paths — so a Supabase public URL and a local relative
# path both just work, no frontend changes needed).
#
# Render's filesystem is wiped on every restart/redeploy — LOCAL
# mode's disk storage is only ever correct for local development,
# never for anything actually hosted.
#
# LOGGING: every step below logs to Render's log stream (via the
# standard `logging` module — Render captures stdout/stderr
# automatically, no extra setup needed). If an upload ever fails
# again, the exact step and exact underlying error will be visible
# in Render's Logs tab — this is deliberate: a bare "502 Bad Gateway"
# with no detail is exactly what made the last failure hard to
# diagnose, and it should never happen silently again.
# ─────────────────────────────────────────────
import logging
import time
import uuid
from pathlib import Path

from app.core.config import settings
from app.core.env_config import IS_ONLINE

log = logging.getLogger("gms.storage")

# Project-relative, not CWD-relative — works identically regardless
# of where the process was launched from (local machine, Render,
# a repo moved to a different computer).
_LOCAL_AVATAR_DIR = Path(__file__).resolve().parent.parent / "static" / "avatars"

_supabase_client = None


class StorageError(Exception):
    """Raised for any storage failure, always with a message that's
    actually useful — which step failed and why, not just "it broke"."""


def _get_supabase_client():
    """Lazily creates the Supabase client — only imported/constructed
    when actually running in ONLINE mode, so LOCAL dev never needs
    the supabase package configured or even reachable."""
    global _supabase_client
    if _supabase_client is not None:
        return _supabase_client

    url = (settings.SUPABASE_URL or "").strip()
    key = settings.SUPABASE_SERVICE_ROLE_KEY or ""

    if not url or not key:
        log.error(
            "storage: SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY is not set "
            "(url_present=%s, key_present=%s). Add both in Render's "
            "Environment Variables tab.", bool(url), bool(key)
        )
        raise StorageError(
            "Supabase Storage isn't configured on this server — "
            "SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY missing."
        )

    # Log the URL being used (safe — it's not secret, it's the same
    # value visible in a browser address bar) so a typo'd project
    # reference is immediately visible by eye in Render's logs,
    # rather than only showing up as an opaque connection error.
    log.info("storage: creating Supabase client for %s (bucket=%s)",
              url, settings.SUPABASE_BUCKET)

    try:
        from supabase import create_client
        _supabase_client = create_client(url, key)
    except Exception as e:
        log.error("storage: failed to CREATE the Supabase client — "
                   "check SUPABASE_URL is exactly correct (no typos in "
                   "the project reference) and SUPABASE_SERVICE_ROLE_KEY "
                   "is the full key with no missing characters. "
                   "Underlying error: %s: %s", type(e).__name__, e)
        raise StorageError(f"Could not connect to Supabase Storage: {e}") from e

    return _supabase_client


def _unique_filename(user_id: int, ext: str) -> str:
    # Same naming scheme regardless of backend — timestamp + random
    # suffix makes collisions between two uploads (even from the same
    # user in the same second) effectively impossible, and never
    # overwrites another user's file since user_id is embedded.
    return f"user{user_id}_{int(time.time())}_{uuid.uuid4().hex[:8]}.{ext}"


def save_avatar(data: bytes, ext: str, content_type: str, user_id: int) -> str:
    """Saves the uploaded bytes to whichever backend is active and
    returns the value to store in users.avatar_url. Raises
    StorageError (with a specific, useful message) on any failure —
    callers should not need to guess what went wrong from the
    exception alone."""
    filename = _unique_filename(user_id, ext)

    if IS_ONLINE:
        client = _get_supabase_client()
        storage_path = f"avatars/{filename}"

        # No "does the avatars/ folder exist" check needed — Supabase
        # Storage folders are purely virtual path prefixes, created
        # implicitly the moment a file is uploaded under them. There
        # is nothing to pre-create here.
        log.info("storage: uploading to bucket=%s path=%s size=%d bytes user_id=%s",
                  settings.SUPABASE_BUCKET, storage_path, len(data), user_id)
        try:
            client.storage.from_(settings.SUPABASE_BUCKET).upload(
                path=storage_path,
                file=data,
                file_options={"content-type": content_type},
            )
        except Exception as e:
            log.error("storage: UPLOAD failed for bucket=%s path=%s — "
                       "common causes: the bucket name doesn't match "
                       "SUPABASE_BUCKET exactly, or the bucket's storage "
                       "policies don't allow the service-role key to "
                       "write. Underlying error: %s: %s",
                       settings.SUPABASE_BUCKET, storage_path, type(e).__name__, e)
            raise StorageError(f"Upload to Supabase Storage failed: {e}") from e

        log.info("storage: upload OK, generating public URL for path=%s", storage_path)
        try:
            public_url = client.storage.from_(settings.SUPABASE_BUCKET).get_public_url(
                storage_path
            )
        except Exception as e:
            log.error("storage: upload succeeded but generating the public "
                       "URL failed — this usually means the bucket isn't "
                       "set to Public. Underlying error: %s: %s",
                       type(e).__name__, e)
            raise StorageError(f"Uploaded, but could not build a URL: {e}") from e

        log.info("storage: done, public_url=%s", public_url)
        return public_url

    _LOCAL_AVATAR_DIR.mkdir(parents=True, exist_ok=True)
    (_LOCAL_AVATAR_DIR / filename).write_bytes(data)
    log.info("storage: saved locally to %s", _LOCAL_AVATAR_DIR / filename)
    # Relative path only — never bake in a host/port (see
    # ApiConfig.resolveMediaUrl on the Flutter side for why).
    return f"/static/avatars/{filename}"


def delete_avatar(avatar_url: str | None) -> None:
    """Removes the stored file for the given avatar_url value, on
    whichever backend is currently active. Safe to call with None or
    a value that doesn't match the expected shape — never raises for
    "nothing to delete", only logs and moves on, since a missing file
    should never block clearing the database reference."""
    if not avatar_url:
        return

    try:
        if IS_ONLINE:
            client = _get_supabase_client()
            # Supabase public URLs look like:
            #   {SUPABASE_URL}/storage/v1/object/public/{bucket}/{path}
            # Pull just {path} back out so we can call remove() with
            # the same relative key upload() used.
            marker = f"/storage/v1/object/public/{settings.SUPABASE_BUCKET}/"
            if marker in avatar_url:
                storage_path = avatar_url.split(marker, 1)[1]
                log.info("storage: deleting old avatar bucket=%s path=%s",
                          settings.SUPABASE_BUCKET, storage_path)
                client.storage.from_(settings.SUPABASE_BUCKET).remove([storage_path])
            else:
                log.warning("storage: avatar_url doesn't match the expected "
                             "Supabase public URL shape, skipping delete: %s",
                             avatar_url)
        else:
            if avatar_url.startswith("/static/avatars/"):
                filename = avatar_url.replace("/static/avatars/", "", 1)
                target = _LOCAL_AVATAR_DIR / filename
                if target.exists():
                    target.unlink()
                    log.info("storage: deleted local file %s", target)
    except Exception as e:
        # A failed delete of the old file should never prevent the
        # user from clearing/replacing their avatar — the database
        # update (clearing avatar_url) is what actually matters to
        # them; an orphaned file is a cleanup issue, not a user-facing
        # failure. Still log it so orphans are at least visible.
        log.warning("storage: failed to delete old avatar %s — leaving it "
                     "orphaned, not blocking the user. Error: %s: %s",
                     avatar_url, type(e).__name__, e)
