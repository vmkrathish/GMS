// ─────────────────────────────────────────────
// core/services/booking_badge_service.dart
//
// Bookings tab badge — counts bookings that genuinely need THIS
// user's attention right now, not just "something changed":
//   As customer: a provider proposed a new time (needs a response),
//                or the advance is due.
//   As provider: a new request is pending, or the customer proposed
//                a new time (needs a response).
// Same polling pattern as ChatBadgeService — pure frontend
// aggregation over data the bookings API already returns, no
// backend changes needed for the badge itself.
// ─────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/foundation.dart';

import '../api/notification_api.dart';
import '../models/notification_service.dart' show NotificationService;
import 'app_visibility.dart';

class BookingBadgeService {
  static final ValueNotifier<int> needsAttention = ValueNotifier<int>(0);

  static Timer? _poller;

  static bool _inFlight = false;

  /// One refresh at a time; skipped while the app is in the background.
  static Future<void> refresh() async {
    if (_inFlight || !AppVisibility.visible.value) return;
    _inFlight = true;
    try {
      await _refresh();
    } finally {
      _inFlight = false;
    }
  }

  /// Bookings badge = number of UNSEEN booking events for this user
  /// (new request, reschedule, response, cancellation, payment,
  /// confirmation), counted on the server: one per real event, so
  /// duplicate pushes never inflate it, and it's the same on every device.
  /// Pending actions are NOT cleared by viewing — they stay on the cards.
  static final ValueNotifier<Map<int, int>> unseenByBooking =
      ValueNotifier<Map<int, int>>(const {});

  static Future<void> _refresh() async {
    final res = await NotificationApi.bookingUnseen();
    if (!res.success || res.data is! Map) return; // offline: keep last state
    final data = res.data as Map;
    final by = <int, int>{};
    final raw = data['by_booking'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final id = int.tryParse('$k');
        final n = int.tryParse('$v') ?? 0;
        if (id != null && n > 0) by[id] = n;
      });
    }
    if (!mapEquals(by, unseenByBooking.value)) unseenByBooking.value = by;
    needsAttention.value = int.tryParse('${data['count']}') ?? 0;
    final total = int.tryParse('${data['unread_total'] ?? ''}');
    if (total != null) NotificationService().unreadCount.value = total;
  }

  /// Opened a booking's details in the app → its events are seen.
  static Future<void> markBookingSeen(int bookingId) async {
    if (!(unseenByBooking.value.containsKey(bookingId))) return;
    final res = await NotificationApi.markBookingSeen(bookingId);
    if (res.success) {
      final by = Map<int, int>.from(unseenByBooking.value)..remove(bookingId);
      unseenByBooking.value = by;
      needsAttention.value = by.values.fold(0, (a, b) => a + b);
    }
  }

  /// Every 3 s while the app is visible (booking requests, time
  /// suggestions, responses, and the notification unread count).
  static void startPolling({Duration every = const Duration(seconds: 3)}) {
    _poller?.cancel();
    AppVisibility.visible.removeListener(_onVisibility);
    AppVisibility.visible.addListener(_onVisibility);
    refresh();
    // ONE request per tick (booking-unseen also returns the bell total);
    // V12–V14 sent a second /unread-count every tick.
    _poller = Timer.periodic(every, (_) => refresh());
  }

  static void _onVisibility() {
    if (AppVisibility.visible.value && _poller != null) {
      refresh(); // back on screen → update right away (incl. bell total)
    }
  }

  static void stopPolling() {
    _poller?.cancel();
    _poller = null;
    AppVisibility.visible.removeListener(_onVisibility);
  }

  static void reset() {
    stopPolling();
    needsAttention.value = 0;
  }
}
