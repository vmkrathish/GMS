# Shared helpers — phone normalization + row serialization
import re
from datetime import datetime
from decimal import Decimal


def normalize_phone(raw: str) -> str:
    """'+91 98765 43210', '098765...', '9876543210' → same canonical form."""
    digits = "".join(ch for ch in (raw or "") if ch.isdigit())
    if len(digits) == 12 and digits.startswith("91"):
        digits = digits[2:]
    if len(digits) == 11 and digits.startswith("0"):
        digits = digits[1:]
    return digits


EMAIL_RE = re.compile(r"^[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$")
NAME_RE = re.compile(r"^[a-zA-Z\s.]+$")


def is_email(value: str) -> bool:
    return bool(EMAIL_RE.match((value or "").strip()))


def is_valid_name(value: str) -> bool:
    v = (value or "").strip()
    return 2 <= len(v) <= 100 and bool(NAME_RE.match(v))


def jsonable(value):
    """Match the old Node JSON output: Decimal → '100.00' string
    (mysql2 returned DECIMAL as string), datetime → ISO string."""
    if isinstance(value, Decimal):
        return f"{value:.2f}"
    if isinstance(value, datetime):
        return value.isoformat()
    return value


def row_to_dict(obj, exclude: set[str] | None = None) -> dict:
    """SQLAlchemy model instance → plain dict with legacy-compatible values."""
    exclude = exclude or set()
    return {
        c.name: jsonable(getattr(obj, c.name))
        for c in obj.__table__.columns
        if c.name not in exclude
    }


def public_user(u) -> dict:
    return {
        "id": u.id,
        "name": u.name,
        "phone": u.phone,
        "email": u.email,
        "role": u.role,
        "city": u.city or "",
        "avatar_url": u.avatar_url,
    }
