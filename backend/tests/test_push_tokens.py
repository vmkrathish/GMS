"""Multi-user / multi-device token registration (Fix 1, server side)."""
import threading

from app.models.models import PushToken
from app.services.notify import PushJob, deliver_push

DEV_A = "device-aaaaaaaa"
DEV_B = "device-bbbbbbbb"


def _job(user_id, title="Hi", body="There"):
    return PushJob(user_id=user_id, title=title, body=body,
                   data={"screen": "chat", "partner_id": "9",
                         "notif_id": "1", "type": "chat",
                         "recipient_id": str(user_id)})


def test_first_registration_creates_one_active_row(env):
    a = env.make_user("A")
    r = env.register(a, "tok-1", "android", DEV_A)
    assert r.status_code == 200 and r.json()["success"] is True
    assert env.active(a["id"]) == [("tok-1", DEV_A)]


def test_reregistering_same_token_is_an_idempotent_upsert(env):
    a = env.make_user("A")
    for _ in range(3):
        assert env.register(a, "tok-1", "android", DEV_A).status_code == 200
    assert len(env.all_tokens()) == 1
    assert env.active(a["id"]) == [("tok-1", DEV_A)]


# ─────────────── token refresh ───────────────

def test_token_refresh_leaves_exactly_one_active_token_per_device(env):
    a = env.make_user("A")
    env.register(a, "tok-old", "web", DEV_A)
    env.register(a, "tok-new", "web", DEV_A)      # FCM rotated the token

    assert env.active(a["id"]) == [("tok-new", DEV_A)]
    assert env.all_tokens()["tok-old"][2] is False

    # Only the live token is ever sent to.
    deliver_push(_job(a["id"]))
    assert env.fcm.tokens_sent() == ["tok-new"]


def test_refresh_on_one_device_does_not_touch_users_other_device(env):
    a = env.make_user("A")
    env.register(a, "phone-1", "android", DEV_A)
    env.register(a, "web-1", "web", DEV_B)
    env.register(a, "phone-2", "android", DEV_A)   # refresh on the phone only

    assert env.active(a["id"]) == sorted([("phone-2", DEV_A), ("web-1", DEV_B)])


# ─────────────── multi-device ───────────────

def test_one_user_on_two_devices_gets_push_on_both(env):
    a = env.make_user("A")
    env.register(a, "phone-1", "android", DEV_A)
    env.register(a, "web-1", "web", DEV_B)

    stats = deliver_push(_job(a["id"]))
    assert stats["sent"] == 2
    assert sorted(env.fcm.tokens_sent()) == ["phone-1", "web-1"]


def test_two_users_on_different_devices_are_independent(env):
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "a-tok", "android", DEV_A)
    env.register(b, "b-tok", "android", DEV_B)
    env.register(a, "a-tok2", "android", DEV_A)    # A refreshes

    assert env.active(b["id"]) == [("b-tok", DEV_B)]
    deliver_push(_job(b["id"]))
    assert env.fcm.tokens_sent() == ["b-tok"]


# ─────────────── account switching on one device ───────────────

def test_account_switch_same_fcm_token_moves_to_new_user(env):
    """Logout/login on the same install where FCM kept the same token."""
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "shared-tok", "android", DEV_A)
    env.register(b, "shared-tok", "android", DEV_A)

    assert env.active(a["id"]) == []
    assert env.active(b["id"]) == [("shared-tok", DEV_A)]
    assert len(env.all_tokens()) == 1                     # no duplicate row

    deliver_push(_job(a["id"]))
    assert env.fcm.calls == []                            # A: nothing
    deliver_push(_job(b["id"]))
    assert env.fcm.tokens_sent() == ["shared-tok"]        # B: delivered


def test_account_switch_new_token_instantly_cuts_off_previous_user(env):
    """Client deleted the FCM token on logout, so B registers a NEW token
    on the same device. A's old token must stop being used right away —
    without waiting for FCM to report it as unregistered."""
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "a-token", "android", DEV_A)
    env.register(b, "b-token", "android", DEV_A)

    assert env.active(a["id"]) == []
    assert env.active(b["id"]) == [("b-token", DEV_A)]

    deliver_push(_job(a["id"]))
    assert env.fcm.calls == []


def test_switch_back_to_original_user_works(env):
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "t1", "android", DEV_A)
    env.register(b, "t2", "android", DEV_A)
    env.register(a, "t3", "android", DEV_A)            # A logs back in

    assert env.active(a["id"]) == [("t3", DEV_A)]
    assert env.active(b["id"]) == []


def test_push_queued_for_old_account_is_not_delivered_after_switch(env):
    """Tokens are resolved at DELIVERY time. If the device switches
    accounts between the commit and the worker running, the previous
    account's push must not reach it."""
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "dev-token", "android", DEV_A)

    job_for_a = _job(a["id"])                           # committed, queued…
    env.register(b, "dev-token", "android", DEV_A)       # …device switches to B

    deliver_push(job_for_a)                              # worker runs now
    assert env.fcm.calls == []


def test_sweep_does_not_touch_devices_without_a_device_id(env):
    """Older clients never sent device_id; they must keep working."""
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "legacy-a", "android")               # no device_id
    env.register(b, "legacy-b", "android")
    assert env.active(a["id"]) == [("legacy-a", None)]
    assert env.active(b["id"]) == [("legacy-b", None)]


# ─────────────── validation / logout ───────────────

def test_malformed_device_id_is_rejected(env):
    a = env.make_user("A")
    for bad in ("short", "has space in it", "x" * 200, "semi;colon-id"):
        r = env.register(a, "t", "android", bad)
        assert r.status_code == 400, bad
    assert env.all_tokens() == {}


def test_missing_token_and_bad_platform_rejected(env):
    a = env.make_user("A")
    assert env.client.post("/api/notifications/push-token",
                           json={"platform": "android"},
                           headers=env.auth(a)).status_code == 400
    assert env.register(a, "t", "symbian", DEV_A).status_code == 400


def test_registration_requires_auth(env):
    r = env.client.post("/api/notifications/push-token",
                        json={"token": "t", "platform": "android"})
    assert r.status_code == 401


def test_logout_deactivates_only_this_device(env):
    a = env.make_user("A")
    env.register(a, "phone", "android", DEV_A)
    env.register(a, "web", "web", DEV_B)

    r = env.client.delete(f"/api/notifications/push-token?device_id={DEV_A}",
                          headers=env.auth(a))
    assert r.status_code == 200 and r.json()["deactivated"] == 1
    assert env.active(a["id"]) == [("web", DEV_B)]


def test_logout_by_token_still_works(env):
    a = env.make_user("A")
    env.register(a, "phone", "android", DEV_A)
    r = env.client.delete("/api/notifications/push-token?token=phone",
                          headers=env.auth(a))
    assert r.json()["deactivated"] == 1
    assert env.active(a["id"]) == []


def test_a_user_cannot_deactivate_someone_elses_token(env):
    a, b = env.make_user("A"), env.make_user("B")
    env.register(a, "a-tok", "android", DEV_A)
    r = env.client.delete("/api/notifications/push-token?token=a-tok",
                          headers=env.auth(b))
    assert r.status_code == 200 and r.json()["deactivated"] == 0
    assert env.active(a["id"]) == [("a-tok", DEV_A)]


def test_logout_requires_token_or_device(env):
    a = env.make_user("A")
    r = env.client.delete("/api/notifications/push-token", headers=env.auth(a))
    assert r.status_code == 400


# ─────────────── DB-level guarantee + race ───────────────

def test_database_itself_forbids_two_active_tokens_for_one_device(env):
    """Belt and braces: even code that bypasses the endpoint can't create
    a doubled-push situation."""
    import pytest
    from sqlalchemy.exc import IntegrityError

    a = env.make_user("A")
    db = env.db_factory()
    try:
        db.add(PushToken(user_id=a["id"], token="t1", platform="web",
                         device_id=DEV_A, is_active=True))
        db.add(PushToken(user_id=a["id"], token="t2", platform="web",
                         device_id=DEV_A, is_active=True))
        with pytest.raises(IntegrityError):
            db.commit()
    finally:
        db.rollback()
        db.close()


def test_concurrent_registrations_for_same_device_never_error_or_double(env):
    """Token-refresh and login-sync can fire together. Whatever the
    interleaving: no 5xx, and exactly one active token for the device."""
    from fastapi.testclient import TestClient

    a = env.make_user("A")
    for round_ in range(8):
        results = []

        def worker(tok):
            c = TestClient(env.app)
            results.append(env.register(a, tok, "web", DEV_A, client=c).status_code)

        ts = [threading.Thread(target=worker, args=(f"r{round_}-{i}",))
              for i in range(3)]
        [t.start() for t in ts]
        [t.join() for t in ts]

        assert results == [200, 200, 200], f"round {round_}: {results}"
        assert len(env.active(a["id"])) == 1, f"round {round_}"
