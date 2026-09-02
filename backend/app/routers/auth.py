# ─────────────────────────────────────────────
# /api/auth — signup, login (+ Firebase OTP path)
# Response shapes identical to the legacy backend.
# ─────────────────────────────────────────────
from fastapi import APIRouter, Depends
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy import or_
from sqlalchemy.orm import Session

from app.core.security import create_access_token, hash_password, verify_password
from app.database.session import get_db
from app.middleware.deps import get_current_user
from app.models.models import User
from app.utils.helpers import is_email, is_valid_name, normalize_phone, public_user

router = APIRouter(prefix="/api/auth", tags=["Auth"])


class SignupIn(BaseModel):
    name: str = ""
    phone: str = ""
    email: str | None = None
    password: str = ""


class LoginIn(BaseModel):
    identifier: str = ""
    password: str = ""


class ChangePasswordIn(BaseModel):
    current_password: str = ""
    new_password: str = ""


def _fail(status: int, message: str, **extra):
    return JSONResponse(status_code=status,
                        content={"success": False, "message": message, **extra})


@router.post("/signup")
def signup(body: SignupIn, db: Session = Depends(get_db)):
    name = (body.name or "").strip()
    phone = normalize_phone(body.phone)
    email = (body.email or "").strip().lower() or None
    password = body.password or ""

    if not is_valid_name(name):
        return _fail(400, "Please enter a valid name (letters only).")
    if len(phone) != 10:
        return _fail(400, "Please enter a valid 10-digit phone number.")
    if email and not is_email(email):
        return _fail(400, "Please enter a valid email address.")
    if len(password) < 4:
        return _fail(400, "Password must be at least 4 characters.")

    dup = db.query(User).filter(
        or_(User.phone == phone, User.email == email if email else False)
    ).first()
    if dup:
        which = "phone number" if dup.phone == phone else "email"
        return _fail(409, f"An account with this {which} already exists. Please sign in.")

    user = User(phone=phone, email=email, name=name, role="customer",
                password_hash=hash_password(password))
    db.add(user)
    db.commit()
    db.refresh(user)

    return JSONResponse(status_code=201, content={
        "success": True,
        "isNewUser": True,
        "token": create_access_token({"id": user.id, "phone": user.phone,
                                      "role": user.role, "name": user.name}),
        "user": public_user(user),
    })


@router.post("/login")
def login(body: LoginIn, db: Session = Depends(get_db)):
    identifier = (body.identifier or "").strip().lower()
    if not identifier:
        return _fail(400, "Enter your phone number or email.")
    if not body.password:
        return _fail(400, "Enter your password.")

    phone = normalize_phone(identifier)
    if "@" not in identifier and len(phone) == 10:
        user = db.query(User).filter(
            User.phone == phone, User.is_active == True).first()  # noqa: E712
    elif is_email(identifier):
        user = db.query(User).filter(
            User.email == identifier, User.is_active == True).first()  # noqa: E712
    else:
        return _fail(400, "Enter a valid phone number or email.")

    if not user:
        return _fail(404, "No account found. Please sign up first.", notRegistered=True)

    if not verify_password(body.password, user.password_hash):
        return _fail(401, "Incorrect password.")

    return {
        "success": True,
        "token": create_access_token({"id": user.id, "phone": user.phone,
                                      "role": user.role, "name": user.name}),
        "user": public_user(user),
    }


@router.put("/change-password")
def change_password(body: ChangePasswordIn,
                     user: User = Depends(get_current_user),
                     db: Session = Depends(get_db)):
    if not verify_password(body.current_password, user.password_hash):
        return _fail(401, "Current password is incorrect.")
    if len(body.new_password or "") < 4:
        return _fail(400, "New password must be at least 4 characters.")
    if body.new_password == body.current_password:
        return _fail(400, "New password must be different from your current password.")

    user.password_hash = hash_password(body.new_password)
    db.commit()
    return {"success": True, "message": "Password updated successfully."}


class VerifyPasswordIn(BaseModel):
    password: str = ""


@router.post("/verify-password")
def verify_password_only(body: VerifyPasswordIn,
                          user: User = Depends(get_current_user)):
    # Live, side-effect-free check used by the Change Password screen —
    # tells the person immediately whether what they just typed for
    # "Current password" is actually correct, rather than waiting
    # until they submit the whole form.
    ok = verify_password(body.password, user.password_hash)
    return {"success": True, "valid": ok}


@router.post("/verify-otp")
def verify_otp():
    # Firebase OTP path — production upgrade. Wire firebase_admin.auth
    # verify_id_token here once the service-account key is configured.
    return _fail(503, "Auth service not configured yet (Firebase key missing on server).")


@router.post("/register")
def register():
    return _fail(503, "Use /api/auth/signup for registration in this version.")
