"""Push payload shape (Fix 2, server side) and FCM failure handling (Fix 3)."""
import logging

from firebase_admin import exceptions, messaging

from app.models.models import Message, Notification, PushToken
from app.services import notify as notify_mod
from app.services.notify import (ANDROID_CHANNEL_ID, PushJob, _Target,
                                 build_message, deliver_push)

DEV = "device-aaaaaaaa"


def _job(user_id, **over):
    data = {"screen": "chat", "partner_id": "9", "notif_id": "42",
            "type": "chat", "recipient_id": str(user_id)}
    base = dict(user_id=user_id, title="New Message", body="Sam sent you a message.",
                data=data)
    base.update(over)
    return PushJob(**base)


def _seed(env, user, tokens):
    """tokens: {token: platform} — inserted directly (distinct devices)."""
    db = env.db_factory()
    try:
        for i, (tok, plat) in enumerate(tokens.items()):
            db.add(PushToken(user_id=user["id"], token=tok, platform=plat,
                             device_id=f"device-{tok}-{i:04d}", is_active=True))
        db.commit()
    finally:
        db.close()


def _state(env):
    return {t: active for t, (_u, _d, active) in env.all_tokens().items()}


# ───────────── payload shape: the duplicate-web-notification guard ─────────────

def test_web_push_is_data_only_so_firebase_never_auto_displays(env):
    """A `notification` block on a web message makes the Firebase SDK
    display it AND our service worker display it → two notifications.
    Web must therefore be data-only, carrying title/body in `data`."""
    msg = build_message(_Target(1, "web-tok", "web"), _job(7))
    assert msg.notification is None
    assert msg.data["title"] == "New Message"
    assert msg.data["body"] == "Sam sent you a message."
    assert msg.webpush.headers["Urgency"] == "high"


def test_android_push_keeps_system_tray_notification_and_channel(env):
    msg = build_message(_Target(1, "and-tok", "android"), _job(7))
    assert msg.notification.title == "New Message"
    assert msg.notification.body == "Sam sent you a message."
    assert msg.android.priority == "high"
    assert msg.android.notification.channel_id == ANDROID_CHANNEL_ID


def test_every_payload_carries_routing_and_dedupe_fields_as_strings(env):
    for platform in ("web", "android"):
        msg = build_message(_Target(1, "t", platform), _job(7))
        assert msg.data["notif_id"] == "42"          # service-worker tag
        assert msg.data["recipient_id"] == "7"       # client-side account guard
        assert msg.data["screen"] == "chat"
        assert msg.data["partner_id"] == "9"
        assert all(isinstance(v, str) for v in msg.data.values())


def test_mixed_devices_get_the_right_shape_in_one_delivery(env):
    u = env.make_user("U")
    _seed(env, u, {"w": "web", "a": "android"})
    deliver_push(_job(u["id"]))
    by_token = {m.token: m for m in env.fcm.calls}
    assert by_token["w"].notification is None
    assert by_token["a"].notification is not None


# ───────────── partial FCM failures ─────────────

def test_mixed_outcomes_are_handled_independently(env):
    u = env.make_user("U")
    _seed(env, u, {"ok": "android", "dead": "web", "flaky": "android",
                   "bad": "android", "mismatch": "web"})
    env.fcm.script = {
        "dead": [messaging.UnregisteredError("gone")],
        "flaky": [exceptions.UnavailableError("503"), None],   # fails, then ok
        "bad": [exceptions.InvalidArgumentError("payload")],
        "mismatch": [messaging.SenderIdMismatchError("other project")],
    }
    slept = []
    stats = deliver_push(_job(u["id"]), sleep=slept.append)

    assert stats["sent"] == 2            # ok + flaky (after retry)
    assert stats["deactivated"] == 2     # dead + mismatch
    assert stats["failed"] == 1          # bad (permanent, not retried)
    assert stats["retried"] == 1
    assert env.fcm.tokens_sent().count("flaky") == 2   # exactly one retry
    assert env.fcm.tokens_sent().count("bad") == 1     # permanent: no retry
    assert len(slept) == 1

    st = _state(env)
    assert st["dead"] is False and st["mismatch"] is False
    assert st["ok"] and st["flaky"] and st["bad"]      # others stay active


def test_transient_failure_is_retried_then_gives_up_without_deactivating(env):
    u = env.make_user("U")
    _seed(env, u, {"t": "android"})
    env.fcm.script = {"t": [exceptions.UnavailableError("503")] * 5}
    slept = []
    stats = deliver_push(_job(u["id"]), sleep=slept.append)

    assert env.fcm.tokens_sent().count("t") == notify_mod.MAX_SEND_ATTEMPTS
    assert stats["failed"] == 1 and stats["sent"] == 0
    assert stats["deactivated"] == 0
    assert _state(env)["t"] is True                    # a 503 is not a dead token
    assert len(slept) == notify_mod.MAX_SEND_ATTEMPTS - 1


def test_quota_exceeded_is_treated_as_transient(env):
    u = env.make_user("U")
    _seed(env, u, {"q": "android"})
    env.fcm.script = {"q": [messaging.QuotaExceededError("slow down"), None]}
    stats = deliver_push(_job(u["id"]), sleep=lambda _s: None)
    assert stats["sent"] == 1 and stats["retried"] == 1


def test_whole_batch_network_failure_is_retried_then_gives_up_without_raising(env):
    u = env.make_user("U")
    _seed(env, u, {"a": "android", "b": "web"})
    env.fcm.whole_call_error = ConnectionError("network down")
    slept = []
    stats = deliver_push(_job(u["id"]), sleep=slept.append)      # must not raise
    assert stats["sent"] == 0 and stats["failed"] == 2
    assert len(slept) == notify_mod.MAX_SEND_ATTEMPTS - 1        # it DID retry
    assert _state(env) == {"a": True, "b": True}                 # tokens kept


def test_whole_batch_programming_error_is_not_retried(env):
    u = env.make_user("U")
    _seed(env, u, {"a": "android"})
    env.fcm.whole_call_error = ValueError("bad message")
    slept = []
    stats = deliver_push(_job(u["id"]), sleep=slept.append)
    assert stats["failed"] == 1 and slept == []                  # permanent: no retry


def test_a_network_blip_that_clears_still_delivers(env):
    u = env.make_user("U")
    _seed(env, u, {"a": "android"})
    calls = {"n": 0}
    real = env.fcm

    def flaky(messages):
        calls["n"] += 1
        if calls["n"] == 1:
            raise exceptions.UnknownError("Unknown error while making remote service calls")
        return real(messages)

    env.notify._fcm_send_each = flaky
    stats = deliver_push(_job(u["id"]), sleep=lambda _s: None)
    assert stats["sent"] == 1 and calls["n"] == 2


def test_dead_token_deactivation_is_scoped_to_that_token_only(env):
    a, b = env.make_user("A"), env.make_user("B")
    _seed(env, a, {"a-dead": "android", "a-ok": "web"})
    _seed(env, b, {"b-tok": "android"})
    env.fcm.script = {"a-dead": [messaging.UnregisteredError("gone")]}
    deliver_push(_job(a["id"]))
    assert _state(env) == {"a-dead": False, "a-ok": True, "b-tok": True}


def test_no_tokens_means_no_fcm_call(env):
    u = env.make_user("U")
    stats = deliver_push(_job(u["id"]))
    assert stats["tokens"] == 0 and env.fcm.calls == []


def test_firebase_not_configured_skips_cleanly(env, monkeypatch):
    u = env.make_user("U")
    _seed(env, u, {"t": "android"})
    monkeypatch.setattr(notify_mod, "_firebase_ready", False)
    stats = deliver_push(_job(u["id"]))
    assert stats["sent"] == 0 and env.fcm.calls == []


def test_deliver_jobs_survives_an_unexpected_error_in_one_job(env, monkeypatch):
    """One poisoned job must not kill the worker or skip the next job."""
    u = env.make_user("U")
    _seed(env, u, {"t": "android"})
    real = notify_mod.deliver_push
    calls = {"n": 0}

    def flaky(job, *a, **k):
        calls["n"] += 1
        if calls["n"] == 1:
            raise RuntimeError("boom")
        return real(job, *a, **k)

    monkeypatch.setattr(notify_mod, "deliver_push", flaky)
    notify_mod._deliver_jobs([_job(u["id"]), _job(u["id"])])
    assert env.fcm.tokens_sent() == ["t"]               # second job still sent


# ───────────── history preserved when push fails ─────────────

def test_notification_history_survives_total_push_failure(env):
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    env.register(rcpt, "r-tok", "android", DEV)
    env.fcm.script = {"r-tok": [exceptions.InvalidArgumentError("x")]}
    env.push.mode = "inline"

    r = env.client.post(f"/api/chats/{rcpt['id']}", json={"body": "hello"},
                        headers=env.auth(sender))
    assert r.status_code == 201                          # request unaffected
    assert env.count(Message, receiver_id=rcpt["id"]) == 1    # message intact
    assert env.count(Notification, user_id=rcpt["id"]) == 0   # chat: push-only (V16)


def test_history_exists_even_when_firebase_is_off(env, monkeypatch):
    sender, rcpt = env.make_user("Sam"), env.make_user("Riya")
    monkeypatch.setattr(notify_mod, "_firebase_ready", False)
    env.push.mode = "inline"
    r = env.client.post(f"/api/chats/{rcpt['id']}", json={"body": "hello"},
                        headers=env.auth(sender))
    assert r.status_code == 201
    assert env.count(Message, receiver_id=rcpt["id"]) == 1
    assert env.count(Notification, user_id=rcpt["id"]) == 0   # chat: push-only (V16)
    assert env.fcm.calls == []


# ───────────── secrets never reach the logs ─────────────

def test_logs_never_contain_token_values(env, caplog):
    u = env.make_user("U")
    secret = "SECRET-FCM-TOKEN-" + "x" * 60
    _seed(env, u, {secret: "android"})
    env.fcm.script = {secret: [messaging.UnregisteredError("gone")]}
    with caplog.at_level(logging.DEBUG, logger="gms"):
        deliver_push(_job(u["id"]))
    assert secret not in caplog.text
    assert "deactivating token_id=" in caplog.text       # but it IS logged


# ───────────── the REAL firebase_admin SDK (no fake) ─────────────

def test_real_sdk_path_with_a_throwaway_key_never_raises_and_keeps_tokens(env, tmp_path, monkeypatch):
    """Drives the genuine SDK end to end: Certificate() parsing, app init,
    message construction and send_each. The key is generated on the fly
    and is NOT a real credential, so Google rejects/can't be reached —
    which is exactly the failure path we need to prove is handled."""
    import json
    import firebase_admin
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa
    from firebase_admin import credentials

    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = key.private_bytes(serialization.Encoding.PEM,
                            serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    path = tmp_path / "throwaway-sa.json"
    path.write_text(json.dumps({
        "type": "service_account", "project_id": "throwaway-local-test",
        "private_key_id": "0" * 40, "private_key": pem,
        "client_email": "t@throwaway-local-test.iam.gserviceaccount.com",
        "client_id": "1", "token_uri": "https://oauth2.googleapis.com/token"}))

    app = firebase_admin.initialize_app(credentials.Certificate(str(path)),
                                        options={"httpTimeout": 3})
    try:
        # Swap ONLY the FCM seam back to the genuine SDK adapter; the
        # database/worker patches from the fixture stay in place.
        monkeypatch.setattr(notify_mod, "_fcm_send_each", env.real_fcm_send_each)
        u = env.make_user("U")
        _seed(env, u, {"real-a": "android", "real-w": "web"})
        stats = deliver_push(_job(u["id"]), sleep=lambda _s: None)   # must not raise
        assert stats["sent"] == 0
        assert stats["failed"] + stats["deactivated"] == 2
        assert _state(env)["real-a"] is True and _state(env)["real-w"] is True
    finally:
        firebase_admin.delete_app(app)
