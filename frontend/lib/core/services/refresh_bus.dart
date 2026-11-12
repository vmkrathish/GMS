// ─────────────────────────────────────────────
// core/services/refresh_bus.dart
//
// Tiny cross-screen "something changed" signal. Screens that
// display bookings listen to this and reload when it ticks.
// Bumped by BookingApi after any create/action call succeeds,
// so a booking made from Home instantly shows up in the
// Bookings tab — regardless of how tabs preserve/discard state.
//
// isRefreshing is a single combined flag every bump*() call pulses
// briefly — this is what the small rotating indicator in GMSHeader
// listens to, so any refresh anywhere (logo tap, re-tapping the
// active tab, a booking action completing) shows the same subtle
// "something just updated" feedback without each screen needing its
// own separate spinner wiring.
// ─────────────────────────────────────────────
import 'dart:async';

import 'package:flutter/foundation.dart';

class RefreshBus {
  static final ValueNotifier<int> bookings = ValueNotifier<int>(0);
  static final ValueNotifier<int> home = ValueNotifier<int>(0);
  static final ValueNotifier<int> profile = ValueNotifier<int>(0);
  static final ValueNotifier<int> map = ValueNotifier<int>(0);
  static final ValueNotifier<int> payments = ValueNotifier<int>(0);
  static final ValueNotifier<int> chat = ValueNotifier<int>(0);

  static final ValueNotifier<bool> isRefreshing = ValueNotifier<bool>(false);
  static Timer? _clearTimer;

  static void _pulse() {
    isRefreshing.value = true;
    _clearTimer?.cancel();
    // Long enough to actually be seen, short enough to never look
    // stuck — most of these reloads finish well within this window.
    _clearTimer = Timer(const Duration(milliseconds: 900), () {
      isRefreshing.value = false;
    });
  }

  static void bumpBookings() {
    bookings.value++;
    _pulse();
  }

  static void bumpHome() {
    home.value++;
    _pulse();
  }

  static void bumpProfile() {
    profile.value++;
    _pulse();
  }

  static void bumpMap() {
    map.value++;
    _pulse();
  }

  static void bumpPayments() {
    payments.value++;
    _pulse();
  }

  static void bumpChat() {
    chat.value++;
    _pulse();
  }

  /// Full app refresh — used when the logo/app name is tapped.
  /// Bumps every signal so whichever tab is currently visible
  /// reloads its data fresh from the database.
  static void bumpAll() {
    bookings.value++;
    home.value++;
    profile.value++;
    map.value++;
    payments.value++;
    chat.value++;
    _pulse();
  }
}
