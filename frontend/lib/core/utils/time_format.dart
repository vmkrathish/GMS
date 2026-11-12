// ─────────────────────────────────────────────
// core/utils/time_format.dart
//
// WhatsApp-style time/date formatting, shared by Chat
// (and anywhere else a "when" needs to feel natural).
// ─────────────────────────────────────────────

/// "8:04 PM" — for inside a chat bubble or list trailing time.
String formatClockTime(DateTime dt) {
  final local = dt;
  final h = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final ampm = local.hour >= 12 ? 'PM' : 'AM';
  final m = local.minute.toString().padLeft(2, '0');
  return '$h:$m $ampm';
}

const _weekdays = [
  'Monday', 'Tuesday', 'Wednesday', 'Thursday',
  'Friday', 'Saturday', 'Sunday',
];
const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// WhatsApp date-separator label: "Today", "Yesterday", weekday name
/// within the last 7 days, else "12 Jul 2026".
String formatDaySeparator(DateTime dt) {
  final local = dt;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final diff = today.difference(that).inDays;

  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdays[local.weekday - 1];
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// WhatsApp conversation-list style: "8:04 PM" for today,
/// "Yesterday", weekday name within a week, else "12/07/26".
String formatListTime(DateTime dt) {
  final local = dt;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final that = DateTime(local.year, local.month, local.day);
  final diff = today.difference(that).inDays;

  if (diff == 0) return formatClockTime(local);
  if (diff == 1) return 'Yesterday';
  if (diff > 1 && diff < 7) return _weekdays[local.weekday - 1];
  final yy = (local.year % 100).toString().padLeft(2, '0');
  return '${local.day.toString().padLeft(2, '0')}/${local.month.toString().padLeft(2, '0')}/$yy';
}

/// WhatsApp-style presence label: "Online now", "5 minutes ago",
/// "2 hours ago", "Yesterday", or a full date beyond a week.
/// Used for "Last seen …" and "Seen …" under sent messages.
String formatRelativeAgo(DateTime dt) {
  final local = dt;
  final now = DateTime.now();
  final diff = now.difference(local);

  if (diff.inSeconds < 60) return 'Online now';
  if (diff.inMinutes < 60) {
    final m = diff.inMinutes;
    return '$m minute${m == 1 ? '' : 's'} ago';
  }
  if (diff.inHours < 24) {
    final h = diff.inHours;
    return '$h hour${h == 1 ? '' : 's'} ago';
  }
  if (diff.inDays == 1) return 'Yesterday';
  if (diff.inDays < 7) return '${diff.inDays} days ago';
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

/// Parses a server datetime string safely, correctly converting to
/// the device's actual local time.
///
/// Postgres/Supabase's CURRENT_TIMESTAMP returns UTC (confirmed:
/// `SHOW timezone` on this database returns `Etc/UTC`) — but FastAPI
/// serializes it as a naive string with no 'Z' or offset suffix
/// (e.g. "2026-08-14T03:52:33"). Dart's DateTime.parse treats a
/// naive string as ALREADY LOCAL by default, which silently
/// misinterpreted UTC as local time — explaining both a wrong
/// message clock time AND a "Last seen" that looked stuck/wrong,
/// since both are just this same ~5.5-hour (UTC vs IST) miscalculation
/// showing up two different ways.
///
/// This works correctly regardless of which timezone the device is
/// actually in — never hardcode an assumption like "the user is in
/// IST" again; always convert from UTC to whatever .toLocal() says.
DateTime? parseServerTime(String? raw) {
  if (raw == null || raw.isEmpty || raw == 'null') return null;
  final normalized = raw.contains('T') ? raw : raw.replaceFirst(' ', 'T');
  final hasExplicitOffset =
      normalized.endsWith('Z') || RegExp(r'[+-]\d\d:?\d\d$').hasMatch(normalized);
  final asUtc = hasExplicitOffset ? normalized : '${normalized}Z';
  final parsed = DateTime.tryParse(asUtc);
  return parsed?.toLocal();
}
