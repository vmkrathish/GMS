// ─────────────────────────────────────────────
// core/services/booking_labels.dart
//
// Status labels from the VIEWER's point of view (pure Dart, unit-tested in
// test/booking_labels_test.dart). The persisted status already records
// the actor — reschedule_by_provider / _by_customer, cancelled_by_provider
// / _by_customer — and the list tells us the viewer's role: "Received" =
// I am the provider, "My Bookings" = I am the customer.
// Before V15 the labels were fixed strings: "Reschedule: You Proposed" for
// every customer proposal (wrong for the provider) and "Cancelled by
// Customer" even when the customer was the one looking.
// ─────────────────────────────────────────────

class BookingLabels {
  static String status(String status, {required bool viewerIsProvider}) {
    switch (status) {
      case 'pending':
        return 'Pending Provider Response';
      case 'awaiting_advance':
        return 'Awaiting Advance Payment';
      case 'confirmed':
        return 'Confirmed';
      case 'in_progress':
        return 'Visiting';
      case 'completed':
        return 'Completed';
      case 'reschedule_by_provider':
        return viewerIsProvider
            ? 'Reschedule: You proposed'
            : 'Reschedule: Provider proposed';
      case 'reschedule_by_customer':
        return viewerIsProvider
            ? 'Reschedule: Customer proposed'
            : 'Reschedule: You proposed';
      case 'rejected':
        return 'Rejected';
      case 'cancelled_by_customer':
        return viewerIsProvider ? 'Cancelled by customer' : 'Cancelled by you';
      case 'cancelled_by_provider':
        return viewerIsProvider ? 'Cancelled by you' : 'Cancelled by provider';
      case 'expired':
        return 'Expired';
      default:
        return status;
    }
  }

  /// A proposed time is only meaningful while a reschedule is open — a
  /// cancelled/confirmed booking keeps the old column value but must not
  /// show "Proposed new time".
  static bool showsProposal(String status) => status.startsWith('reschedule_');
}
