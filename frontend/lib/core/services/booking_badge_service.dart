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

import '../api/booking_api.dart';

class BookingBadgeService {
  static final ValueNotifier<int> needsAttention = ValueNotifier<int>(0);

  static Timer? _poller;

  static Future<void> refresh() async {
    final results = await Future.wait([
      BookingApi.getMyBookings(),
      BookingApi.getReceivedBookings(),
    ]);
    final mineRes = results[0];
    final receivedRes = results[1];

    int count = 0;

    if (mineRes.success && mineRes.data is Map && mineRes.data['bookings'] is List) {
      for (final raw in (mineRes.data['bookings'] as List)) {
        final b = Map<String, dynamic>.from(raw as Map);
        final status = (b['status'] ?? '').toString();
        // As customer: provider proposed a new time, or advance is due.
        if (status == 'reschedule_by_provider' || status == 'awaiting_advance') {
          count++;
        }
      }
    }

    if (receivedRes.success && receivedRes.data is Map && receivedRes.data['bookings'] is List) {
      for (final raw in (receivedRes.data['bookings'] as List)) {
        final b = Map<String, dynamic>.from(raw as Map);
        final status = (b['status'] ?? '').toString();
        // As provider: a new request, or customer proposed a new time.
        if (status == 'pending' || status == 'reschedule_by_customer') {
          count++;
        }
      }
    }

    needsAttention.value = count;
  }

  static void startPolling({Duration every = const Duration(seconds: 20)}) {
    _poller?.cancel();
    refresh();
    _poller = Timer.periodic(every, (_) => refresh());
  }

  static void stopPolling() {
    _poller?.cancel();
    _poller = null;
  }

  static void reset() {
    stopPolling();
    needsAttention.value = 0;
  }
}
