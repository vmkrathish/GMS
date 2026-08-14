# ─────────────────────────────────────────────
# app/models/models.py — all 9 GMS tables as ORM classes
# These mirror sql/gms_full_setup.sql exactly. Alembic
# compares THESE classes against the live DB to generate
# future migrations.
# ─────────────────────────────────────────────
from sqlalchemy import (
    DECIMAL,
    TIMESTAMP,
    BigInteger,
    Boolean,
    Column,
    DateTime,
    Enum,
    ForeignKey,
    Integer,
    String,
    Text,
    text,
)
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import relationship

from app.database.session import Base


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, autoincrement=True)
    phone = Column(String(15), nullable=False, unique=True, index=True)
    dial_code = Column(String(6), nullable=False, server_default="+91")
    email = Column(String(190), unique=True)
    name = Column(String(100), nullable=False, server_default="")
    password_hash = Column(String(255))  # bcrypt (hashed directly, no passlib) — see core/security.py
    avatar_url = Column(String(500))
    bio = Column(Text)
    role = Column(Enum("customer", "provider"), nullable=False, server_default="customer")

    # You-page live location + full address model
    location_text = Column(String(150), nullable=False, server_default="")
    country = Column(String(80), nullable=False, server_default="India")
    address_line1 = Column(String(200), nullable=False, server_default="")
    area_street_village = Column(String(200), nullable=False, server_default="")
    landmark = Column(String(200), nullable=False, server_default="")
    pincode = Column(String(10), nullable=False, server_default="")
    city = Column(String(100), nullable=False, server_default="")
    district = Column(String(100), nullable=False, server_default="")
    state = Column(String(100), nullable=False, server_default="")
    latitude = Column(DECIMAL(10, 7))
    longitude = Column(DECIMAL(10, 7))

    fcm_token = Column(Text)
    last_seen_at = Column(DateTime)   # bumped on every authenticated request
    is_active = Column(Boolean, nullable=False, server_default=text("TRUE"))
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))
    updated_at = Column(
        DateTime,
        server_default=text("CURRENT_TIMESTAMP")  # actual auto-update on row
        # change is handled by the set_updated_at() trigger in the SQL
        # schema (Postgres has no MySQL-style "ON UPDATE" column option),
    )

    services = relationship("Service", back_populates="provider")


class ServiceCategory(Base):
    __tablename__ = "service_categories"

    id = Column(Integer, primary_key=True, autoincrement=True)
    name = Column(String(80), nullable=False, unique=True)
    icon_name = Column(String(80), nullable=False, server_default="build")
    emoji = Column(String(16), nullable=False, server_default="🛠️")
    is_active = Column(Boolean, nullable=False, server_default=text("TRUE"))
    sort_order = Column(Integer, nullable=False, server_default=text("0"))
    is_remote = Column(Boolean, nullable=False, server_default=text("FALSE"))


class Service(Base):
    __tablename__ = "services"

    id = Column(Integer, primary_key=True, autoincrement=True)
    provider_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    category_id = Column(Integer, ForeignKey("service_categories.id"), nullable=False, index=True)
    title = Column(String(150), nullable=False)
    description = Column(Text)
    price = Column(DECIMAL(10, 2), nullable=False, server_default=text("0.00"))
    price_unit = Column(Enum("fixed", "per_hour", "per_day"), nullable=False, server_default="fixed")
    city = Column(String(100), nullable=False, server_default="", index=True)
    is_primary = Column(Boolean, nullable=False, server_default=text("FALSE"))
    is_active = Column(Boolean, nullable=False, server_default=text("TRUE"))
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))
    updated_at = Column(
        DateTime,
        server_default=text("CURRENT_TIMESTAMP")  # actual auto-update on row
        # change is handled by the set_updated_at() trigger in the SQL
        # schema (Postgres has no MySQL-style "ON UPDATE" column option),
    )

    provider = relationship("User", back_populates="services")
    category = relationship("ServiceCategory")


BOOKING_STATUSES = (
    "pending",
    "awaiting_advance",
    "confirmed",
    "in_progress",
    "completed",
    "reschedule_by_provider",
    "reschedule_by_customer",
    "rejected",
    "cancelled_by_customer",
    "cancelled_by_provider",
    "expired",
)


class Booking(Base):
    __tablename__ = "bookings"

    id = Column(Integer, primary_key=True, autoincrement=True)
    customer_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    provider_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    service_id = Column(Integer, ForeignKey("services.id"), nullable=False)
    status = Column(Enum(*BOOKING_STATUSES), nullable=False, server_default="pending", index=True)
    scheduled_at = Column(DateTime)      # agreed time
    proposed_time = Column(DateTime)     # current reschedule proposal
    advance_amount = Column(DECIMAL(10, 2))
    advance_paid = Column(Boolean, nullable=False, server_default=text("FALSE"))
    payment_deadline = Column(DateTime)
    address = Column(Text)
    customer_lat = Column(DECIMAL(10, 7))   # pinned/current location at booking time
    customer_lng = Column(DECIMAL(10, 7))
    notes = Column(Text)
    cancel_reason = Column(Text)
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))
    updated_at = Column(
        DateTime,
        server_default=text("CURRENT_TIMESTAMP")  # actual auto-update on row
        # change is handled by the set_updated_at() trigger in the SQL
        # schema (Postgres has no MySQL-style "ON UPDATE" column option),
    )

    customer = relationship("User", foreign_keys=[customer_id])
    provider = relationship("User", foreign_keys=[provider_id])
    service = relationship("Service")


class BookingEvent(Base):
    __tablename__ = "booking_events"

    id = Column(Integer, primary_key=True, autoincrement=True)
    booking_id = Column(Integer, ForeignKey("bookings.id", ondelete="CASCADE"), nullable=False, index=True)
    actor_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    actor_role = Column(Enum("customer", "provider", "system"), nullable=False)
    action = Column(String(40), nullable=False)
    reason = Column(Text)
    proposed_time = Column(DateTime)
    amount = Column(DECIMAL(10, 2))
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))

    actor = relationship("User")


class Notification(Base):
    __tablename__ = "notifications"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    title = Column(String(200), nullable=False)
    body = Column(Text, nullable=False)
    type = Column(String(50), nullable=False, server_default="general")
    ref_id = Column(Integer)
    # Deep-link navigation metadata — e.g. {"screen": "chat", "chat_id": 12,
    # "sender_id": 7}. ref_id alone can't carry enough for every event type
    # (a chat notification needs both the conversation and the sender).
    data = Column(JSONB, nullable=False, server_default=text("'{}'::jsonb"))
    is_read = Column(Boolean, nullable=False, server_default=text("FALSE"), index=True)
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))


class PushToken(Base):
    # One row per device. A single GMS account logged into a phone,
    # a tablet, and a browser tab has three active rows here — this
    # is what actually makes multi-device push possible, replacing
    # the old single users.fcm_token column (kept for now for
    # backward compatibility, but no longer the source of truth).
    __tablename__ = "user_push_tokens"

    id = Column(Integer, primary_key=True, autoincrement=True)
    user_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    token = Column(Text, nullable=False, unique=True)
    platform = Column(String(20), nullable=False, server_default="android")  # android | web | ios
    device_id = Column(String(200))
    is_active = Column(Boolean, nullable=False, server_default=text("TRUE"), index=True)
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))
    updated_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))
    last_seen_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))


class SearchTerm(Base):
    __tablename__ = "search_terms"

    id = Column(Integer, primary_key=True, autoincrement=True)
    term = Column(String(120), nullable=False, unique=True, index=True)
    category_id = Column(Integer, ForeignKey("service_categories.id", ondelete="SET NULL"))
    source = Column(Enum("seed", "user", "admin"), nullable=False, server_default="seed")
    hit_count = Column(Integer, nullable=False, server_default=text("0"))
    is_approved = Column(Boolean, nullable=False, server_default=text("TRUE"))
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))


class Review(Base):
    __tablename__ = "reviews"

    id = Column(Integer, primary_key=True, autoincrement=True)
    booking_id = Column(Integer, ForeignKey("bookings.id", ondelete="CASCADE"), nullable=False, unique=True)
    customer_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    provider_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    rating = Column(Integer, nullable=False)
    comment = Column(Text)
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))


class Message(Base):
    __tablename__ = "messages"

    id = Column(BigInteger, primary_key=True, autoincrement=True)
    sender_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    receiver_id = Column(Integer, ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    body = Column(Text, nullable=False)
    is_read = Column(Boolean, nullable=False, server_default=text("FALSE"))
    read_at = Column(DateTime)   # precise "Seen at" timestamp
    delivered_at = Column(DateTime)  # set the moment the recipient's
    # client is confirmed online (polls conversations or opens the
    # thread) — the middle state between "sent" (single tick) and
    # "read" (blue double tick): grey double tick.
    created_at = Column(DateTime, server_default=text("CURRENT_TIMESTAMP"))
