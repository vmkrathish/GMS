# /api/users — profile (full You-page address model), FCM token, avatar
import logging

from fastapi import APIRouter, Depends, File, Request, UploadFile
from fastapi.responses import JSONResponse
from sqlalchemy import text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm import Session

from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import User
from app.services import storage
from app.services.storage import StorageError
from app.utils.helpers import jsonable
from app.utils.helpers import is_email, normalize_phone, row_to_dict

log = logging.getLogger("gms.users")

router = APIRouter(prefix="/api/users", tags=["Users"])

# Whitelist — exactly the fields the You page saves.
# avatar_url is deliberately excluded: it can ONLY be set via the
# dedicated POST /me/avatar upload endpoint below, which validates
# the file and writes a server-hosted URL — never an arbitrary
# string, local device path, or accidental bulk value.
ALLOWED = [
    "name", "email", "phone", "bio", "dial_code",
    "location_text", "country", "address_line1", "area_street_village",
    "landmark", "pincode", "city", "district", "state", "latitude", "longitude",
]


def _user_payload(u: User) -> dict:
    return row_to_dict(u, exclude={"fcm_token"})


@router.get("/me")
def get_me(user: User = Depends(get_current_user)):
    return {"success": True, "user": _user_payload(user)}


@router.put("/me")
def update_me(body: dict, user: User = Depends(get_current_user),
              db: Session = Depends(get_db)):
    changed = False
    for key in ALLOWED:
        if key in body:
            value = body[key]
            if isinstance(value, str):
                value = value.strip()
                if key == "email":
                    value = value.lower() or None
                    if value and not is_email(value):
                        return JSONResponse(status_code=400, content={
                            "success": False,
                            "message": "Please enter a valid email address.",
                        })
                if key == "phone":
                    value = normalize_phone(value)
                    if len(value) != 10:
                        return JSONResponse(status_code=400, content={
                            "success": False,
                            "message": "Please enter a valid 10-digit phone number.",
                        })
                if key == "bio" and len(value) > 500:
                    return JSONResponse(status_code=400, content={
                        "success": False,
                        "message": "Bio must be 500 characters or fewer.",
                    })
            setattr(user, key, value)
            changed = True
    if not changed:
        return JSONResponse(status_code=400, content={
            "success": False, "message": "No valid fields to update."})
    try:
        db.commit()
    except IntegrityError:
        db.rollback()
        return JSONResponse(status_code=409, content={
            "success": False,
            "message": "That email or phone number is already used by another account."})
    db.refresh(user)
    return {"success": True, "user": _user_payload(user)}


@router.put("/fcm")
def update_fcm(body: dict, user: User = Depends(get_current_user),
               db: Session = Depends(get_db)):
    user.fcm_token = body.get("fcm_token")
    db.commit()
    return {"success": True}


# ── POST /api/users/me/avatar ─────────────────
# Dedicated avatar upload — the ONLY path that can set avatar_url.
# MVP: stores the file locally under app/static/avatars and returns
# a server-hosted URL. Swap the storage call for Cloudinary later
# (master plan Step 6) without touching the response contract.
ALLOWED_IMAGE_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_AVATAR_BYTES = 5 * 1024 * 1024  # 5 MB


@router.post("/me/avatar")
async def upload_avatar(
    request: Request,
    file: UploadFile = File(...),
    user: User = Depends(get_current_user),
    db: Session = Depends(get_db),
):
    log.info("avatar upload: user_id=%s content_type=%s filename=%s",
              user.id, file.content_type, file.filename)

    if file.content_type not in ALLOWED_IMAGE_TYPES:
        log.warning("avatar upload rejected: user_id=%s bad content_type=%s",
                     user.id, file.content_type)
        return JSONResponse(status_code=400, content={
            "success": False,
            "message": "Please upload a JPG, PNG, or WEBP image."})

    data = await file.read()
    if len(data) > MAX_AVATAR_BYTES:
        log.warning("avatar upload rejected: user_id=%s file too large (%d bytes)",
                     user.id, len(data))
        return JSONResponse(status_code=400, content={
            "success": False,
            "message": "Image must be smaller than 5 MB."})

    ext = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}[file.content_type]

    # Deletes whatever the user's PREVIOUS avatar was (if any) before
    # saving the new one, on whichever backend is currently active —
    # avoids leaving orphaned files behind on every re-upload.
    storage.delete_avatar(user.avatar_url)

    try:
        new_avatar_url = storage.save_avatar(
            data=data, ext=ext, content_type=file.content_type, user_id=user.id
        )
    except StorageError as e:
        # storage.py already logged exactly which step failed and why
        # (client creation / upload / URL generation) — this is just
        # the HTTP-facing message, kept specific rather than generic.
        log.error("avatar upload FAILED for user_id=%s: %s", user.id, e)
        return JSONResponse(status_code=502, content={
            "success": False,
            "message": str(e)})
    except Exception as e:
        # Anything unexpected that storage.py didn't already wrap —
        # still logged with full detail, never a bare silent 502.
        log.exception("avatar upload: UNEXPECTED error for user_id=%s", user.id)
        return JSONResponse(status_code=502, content={
            "success": False,
            "message": f"Could not save the image right now: {e}"})

    # Store exactly what save_avatar() returned — a relative path in
    # LOCAL mode, a full Supabase public URL in ONLINE mode. Either
    # form is handled correctly client-side by
    # ApiConfig.resolveMediaUrl(), no branching needed there.
    user.avatar_url = new_avatar_url
    db.commit()
    db.refresh(user)

    log.info("avatar upload OK: user_id=%s avatar_url=%s", user.id, new_avatar_url)
    return {"success": True, "user": _user_payload(user)}


@router.delete("/me/avatar")
def delete_avatar(user: User = Depends(get_current_user),
                   db: Session = Depends(get_db)):
    storage.delete_avatar(user.avatar_url)
    user.avatar_url = None
    db.commit()
    db.refresh(user)
    return {"success": True, "user": _user_payload(user)}


@router.get("/{user_id}")
def get_user(user_id: int, _: User = Depends(get_current_user),
             db: Session = Depends(get_db)):
    u = db.get(User, user_id)
    if not u or not u.is_active:
        return JSONResponse(status_code=404, content={
            "success": False, "message": "User not found."})
    return {"success": True, "user": {
        "id": u.id, "name": u.name, "city": u.city,
        "avatar_url": u.avatar_url, "bio": u.bio, "role": u.role,
        "latitude": u.latitude, "longitude": u.longitude,
    }}


@router.get("/{provider_id}/reviews")
def get_provider_reviews(provider_id: int, limit: int = 20, offset: int = 0,
                         _: User = Depends(get_current_user),
                         db: Session = Depends(get_db)):
    """Individual customer reviews for a provider — newest first.
    This is what a rating SUMMARY ("4.8 (12)") couldn't show on its
    own: who said what, and when. Didn't exist as an endpoint before.
    """
    limit = min(limit, 50)
    rows = db.execute(text("""
        SELECT r.id, r.rating, r.comment, r.created_at,
               c.name AS customer_name, c.avatar_url AS customer_avatar
        FROM reviews r
        JOIN users c ON c.id = r.customer_id
        WHERE r.provider_id = :pid
        ORDER BY r.created_at DESC
        LIMIT :limit OFFSET :offset
    """), {"pid": provider_id, "limit": limit, "offset": offset}).mappings().all()

    total = db.execute(text(
        "SELECT COUNT(*) FROM reviews WHERE provider_id = :pid"),
        {"pid": provider_id}).scalar()

    return {"success": True,
            "reviews": [{k: jsonable(v) for k, v in r.items()} for r in rows],
            "total": total, "has_more": offset + len(rows) < total}
