// ─────────────────────────────────────────────
// core/services/app_navigation.dart
//
// Opening a notification lands INSIDE the normal app shell (GMSMainPage:
// header, bottom navigation, Material styling) instead of pushing a bare
// screen on top. Before V13 the booking tap/View pushed `BookingsScreen`
// as its own route; that screen is a tab body with no Scaffold, so it
// rendered with Flutter's no-Material fallback text style (red text,
// yellow underlines) under the status bar.
//
// FcmService asks for "Bookings tab + booking 42"; GMSMainPage switches
// tab and BookingsScreen selects Received/My Bookings, highlights the
// card and opens its details.
// ─────────────────────────────────────────────
import 'package:flutter/foundation.dart';

class BookingFocusRequest {
  final int? bookingId;

  /// When true (the notification's View), opening the details must NOT
  /// mark the booking's other events seen — View already marked its own.
  final bool fromView;
  final int serial;
  const BookingFocusRequest(this.bookingId, this.fromView, this.serial);
}

class AppNavigation {
  /// Index of the Bookings tab in GMSMainPage._screens.
  static const int bookingsTab = 4;

  /// A tab the shell should switch to (consumed by GMSMainPage).
  static final ValueNotifier<int?> tabRequest = ValueNotifier<int?>(null);

  /// The booking BookingsScreen should show (consumed by it).
  static final ValueNotifier<BookingFocusRequest?> bookingFocus =
      ValueNotifier<BookingFocusRequest?>(null);

  static int _serial = 0;

  static void openBooking(int? bookingId, {bool fromView = false}) {
    bookingFocus.value = BookingFocusRequest(bookingId, fromView, ++_serial);
    tabRequest.value = null; // re-fire even if already on Bookings
    tabRequest.value = bookingsTab;
  }
}
