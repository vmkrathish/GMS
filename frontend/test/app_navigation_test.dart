// Run with:  flutter test test/app_navigation_test.dart
// Notification → in-app routing requests (the shell/tab switch itself and
// the real notification taps need a device).
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/app_navigation.dart';

void main() {
  test('opening a booking asks for the Bookings tab and that booking', () {
    final tabs = <int?>[];
    void l() => tabs.add(AppNavigation.tabRequest.value);
    AppNavigation.tabRequest.addListener(l);
    AppNavigation.openBooking(42);
    AppNavigation.tabRequest.removeListener(l);
    expect(tabs.last, AppNavigation.bookingsTab);
    final f = AppNavigation.bookingFocus.value!;
    expect(f.bookingId, 42);
    expect(f.fromView, isFalse);
  });

  test('every request is new (same booking twice still re-fires)', () {
    AppNavigation.openBooking(7, fromView: true);
    final a = AppNavigation.bookingFocus.value!;
    AppNavigation.openBooking(7, fromView: true);
    final b = AppNavigation.bookingFocus.value!;
    expect(b.serial, greaterThan(a.serial));
    expect(b.fromView, isTrue); // View: only its own event is marked seen
  });

  test('re-fires the tab request even when already requested', () {
    var fired = 0;
    void l() {
      if (AppNavigation.tabRequest.value == AppNavigation.bookingsTab) fired++;
    }
    AppNavigation.tabRequest.addListener(l);
    AppNavigation.openBooking(1);
    AppNavigation.openBooking(1);
    AppNavigation.tabRequest.removeListener(l);
    expect(fired, 2);
  });
}
