// ─────────────────────────────────────────────
// core/services/chat_push.dart
//
// Pure-Dart rules for chat pushes (unit-tested in test/chat_push_test.dart).
// Must match the backend (routers/chats.py conversation_tag):
//   • one notification slot per conversation: tag "gms-chat-<partnerId>"
//     — the Android system tray (FCM, id 0) and the app's own foreground
//     popup (flutter_local_notifications, id 0 + same tag) share it, so a
//     message never shows twice and new messages update that chat's entry;
//   • message_id in the push data is what the device acknowledges for the
//     "delivered" (two grey ticks) receipt;
//   • `recent` = JSON list [{"t": text, "ts": iso}] of the sender's newest
//     unread messages (oldest first) → the lines of the expanded
//     conversation notification.
// ─────────────────────────────────────────────
import 'dart:convert';

/// One line of a conversation notification.
class ChatLine {
  final String text;
  final DateTime time;
  const ChatLine(this.text, this.time);
}

class ChatPush {
  /// "View" on booking/payment notifications (the only thing that marks
  /// that notification read).
  static const String viewActionId = 'gms_view';

  /// Lines shown at most (the backend sends at most 5 as well).
  static const int maxLines = 5;

  /// Absolute URL of the sender's photo, or null (→ initial fallback).
  static String? avatarUrl(Map<String, dynamic> data, String serverRoot) {
    final raw = '${data['sender_avatar'] ?? ''}'.trim();
    if (raw.isEmpty) return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '$serverRoot$raw';
    return null;
  }

  // ── booking / payment events ─────────────────────────────────────
  static bool isBookingEvent(Map<String, dynamic> data) =>
      '${data['screen']}' == 'booking';

  static int? notifId(Map<String, dynamic> data) =>
      int.tryParse('${data['notif_id'] ?? ''}');

  static int? bookingId(Map<String, dynamic> data) =>
      int.tryParse('${data['booking_id'] ?? ''}');

  /// Same tag the backend puts on the FCM tray entry (notify.py), so the
  /// app's notification (with View) replaces it.
  static String? eventTag(Map<String, dynamic> data) {
    final id = '${data['notif_id'] ?? ''}';
    return id.isEmpty ? null : 'gms-n-$id';
  }
  /// Android notification id used together with [tagFor]; FCM's own
  /// tray notifications with a tag always use id 0.
  static const int notificationId = 0;

  static String tagFor(Object partnerId) => 'gms-chat-$partnerId';

  static bool isChat(Map<String, dynamic> data) => '${data['type']}' == 'chat';

  /// The conversation's tag, or null for non-chat pushes.
  static String? conversationTag(Map<String, dynamic> data) {
    if (!isChat(data)) return null;
    final tag = (data['conversation_tag'] ?? '').toString();
    if (tag.isNotEmpty) return tag;
    final partner = (data['partner_id'] ?? '').toString();
    return partner.isEmpty ? null : tagFor(partner);
  }

  /// The other person in the conversation (= the sender of the push).
  static int? partnerId(Map<String, dynamic> data) =>
      isChat(data) ? int.tryParse('${data['partner_id'] ?? ''}') : null;

  static String senderName(Map<String, dynamic> data) {
    final t = (data['title'] ?? '').toString().trim();
    return t.isEmpty ? 'GMS' : t;
  }

  /// Conversation lines, oldest first. Falls back to the push body when
  /// an older backend sent no `recent` (or it is malformed).
  static List<ChatLine> recentLines(Map<String, dynamic> data,
      {DateTime? now}) {
    final fallbackTime = now ?? DateTime.now();
    final out = <ChatLine>[];
    try {
      final raw = jsonDecode('${data['recent'] ?? ''}');
      if (raw is List) {
        for (final e in raw) {
          if (e is! Map) continue;
          final text = '${e['t'] ?? ''}'.trim();
          if (text.isEmpty) continue;
          out.add(ChatLine(
              text, DateTime.tryParse('${e['ts'] ?? ''}') ?? fallbackTime));
        }
      }
    } catch (_) {
      // fall through to the body
    }
    if (out.isEmpty) {
      final body = '${data['body'] ?? ''}'.trim();
      if (body.isNotEmpty) out.add(ChatLine(body, fallbackTime));
    }
    return out.length > maxLines ? out.sublist(out.length - maxLines) : out;
  }

  /// The chat message this push is about, or null.
  static int? messageId(Map<String, dynamic> data) =>
      isChat(data) ? int.tryParse('${data['message_id'] ?? ''}') : null;
}
