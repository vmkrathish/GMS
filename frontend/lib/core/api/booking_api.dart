// Booking endpoints — mirrors gms_backend /api/bookings
import '../config/api_endpoints.dart';
import '../services/api_service.dart';
import '../services/refresh_bus.dart';

class BookingApi {
  static Future<ApiResult> createBooking({
    required int serviceId,
    DateTime? scheduledAt,
    String? address,
    String? notes,
    double? latitude,
    double? longitude,
  }) async {
    final res = await ApiService.post(ApiEndpoints.bookings, {
      'service_id': serviceId,
      if (scheduledAt != null) 'scheduled_at': scheduledAt.toIso8601String(),
      if (address != null) 'address': address,
      if (notes != null) 'notes': notes,
      if (latitude != null) 'customer_lat': latitude,
      if (longitude != null) 'customer_lng': longitude,
    });
    if (res.success) RefreshBus.bumpBookings();
    return res;
  }

  /// Bookings I made (as a seeker).
  static Future<ApiResult> getMyBookings() =>
      ApiService.get(ApiEndpoints.myBookings);

  /// Bookings I received (as a provider) — dual-role support.
  static Future<ApiResult> getReceivedBookings() =>
      ApiService.get(ApiEndpoints.receivedBookings);

  static Future<ApiResult> getBookingById(int id) =>
      ApiService.get(ApiEndpoints.bookingById(id));

  /// Workflow actions: accept | reject | reschedule | accept_proposal |
  /// counter_proposal | pay_advance | cancel | start | complete
  static Future<ApiResult> action(
    int id,
    String action, {
    String? reason,
    DateTime? proposedTime,
    double? advanceAmount,
    DateTime? paymentDeadline,
  }) async {
    final res = await ApiService.put(ApiEndpoints.bookingAction(id), {
      'action': action,
      if (reason != null) 'reason': reason,
      if (proposedTime != null)
        'proposed_time': proposedTime.toIso8601String(),
      if (advanceAmount != null) 'advance_amount': advanceAmount,
      if (paymentDeadline != null)
        'payment_deadline': paymentDeadline.toIso8601String(),
    });
    if (res.success) RefreshBus.bumpBookings();
    return res;
  }

  /// Booking timeline (every action with timestamps + reasons).
  static Future<ApiResult> getEvents(int id) =>
      ApiService.get(ApiEndpoints.bookingEvents(id));
}
