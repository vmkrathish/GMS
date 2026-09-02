# Notification service — DB insert + (optional) FCM push to
# every active device the user is logged into.
#
# Upgraded from the original single-token version: that one only
# ever sent to users.fcm_token (one device). This queries
# user_push_tokens instead, so a person logged into a phone AND a
# browser tab genuinely gets push on both — a core requirement, not
# an edge case.
import logging
import os

from sqlalchemy.orm import Session

from app.core.config import settings
from app.models.models import Notification, PushToken

log = logging.getLogger("gms.notify")

_firebase_ready = False
try:  # pragma: no cover
    if os.path.exists(settings.GOOGLE_APPLICATION_CREDENTIALS):
        import firebase_admin
        from firebase_admin import credentials

        firebase_admin.initialize_app(
            credentials.Certificate(settings.GOOGLE_APPLICATION_CREDENTIALS)
        )
        _firebase_ready = True
        log.info("notify: Firebase Admin SDK initialized")
    else:
        log.info("notify: no Firebase credential file at %s — push disabled, "
                 "notification history still works",
                 settings.GOOGLE_APPLICATION_CREDENTIALS)
except Exception as e:
    _firebase_ready = False
    log.warning("notify: Firebase init failed (%s: %s) — push disabled, "
               "notification history still works", type(e).__name__, e)


def notify(db: Session, user_id: int, title: str, body: str,
           type_: str = "general", ref_id: int | None = None,
           data: dict | None = None) -> None:
    """Creates the permanent notification-history row FIRST, then
    attempts push as a best-effort extra — the history row exists
    regardless of whether push succeeds, fails, or isn't configured
    at all. This ordering matters: a push failure must never mean
    the person also doesn't see it in-app.

    Logs every stage of the chain explicitly (event -> recipient ->
    tokens found -> FCM attempted -> FCM result), so a failure
    anywhere in the pipeline is visible in Render's logs rather than
    a silent gap — never logs the token value or any credential.
    """
    db.add(Notification(user_id=user_id, title=title, body=body,
                        type=type_, ref_id=ref_id, data=data or {}))
    log.info("notify: event created — type=%s recipient user_id=%s",
             type_, user_id)

    if not _firebase_ready:
        log.info("notify: FCM push skipped (Firebase not initialized) — "
                 "recipient user_id=%s, history record still created",
                 user_id)
        return

    tokens = (db.query(PushToken)
              .filter(PushToken.user_id == user_id, PushToken.is_active == True)  # noqa: E712
              .all())
    log.info("notify: recipient user_id=%s — active push tokens found: %d",
             user_id, len(tokens))
    if not tokens:
        return

    from firebase_admin import messaging

    invalid_token_ids = []
    sent_count = 0
    for pt in tokens:
        try:
            messaging.send(messaging.Message(
                token=pt.token,
                notification=messaging.Notification(title=title, body=body),
                data={k: str(v) for k, v in (data or {}).items()},
            ))
            sent_count += 1
            log.info("notify: FCM send SUCCESS — recipient user_id=%s "
                     "platform=%s token_id=%s", user_id, pt.platform, pt.id)
        except messaging.UnregisteredError:
            # This exact device's token is dead (uninstalled, cleared
            # data, etc.) — deactivate only this one. Every other
            # active device for this user still gets their push.
            invalid_token_ids.append(pt.id)
            log.info("notify: FCM token invalid/unregistered — "
                     "deactivating token_id=%s (recipient user_id=%s, "
                     "other devices unaffected)", pt.id, user_id)
        except Exception as e:
            log.warning("notify: FCM send FAILED — recipient user_id=%s "
                       "platform=%s token_id=%s error=%s: %s",
                       user_id, pt.platform, pt.id, type(e).__name__, e)

    log.info("notify: recipient user_id=%s — FCM attempted for %d token(s), "
             "%d succeeded, %d invalid", user_id, len(tokens), sent_count,
             len(invalid_token_ids))

    if invalid_token_ids:
        (db.query(PushToken)
         .filter(PushToken.id.in_(invalid_token_ids))
         .update({"is_active": False}, synchronize_session=False))
