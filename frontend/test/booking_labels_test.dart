// Run with:  flutter test test/booking_labels_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/booking_labels.dart';

void main() {
  String asProvider(String s) => BookingLabels.status(s, viewerIsProvider: true);
  String asCustomer(String s) => BookingLabels.status(s, viewerIsProvider: false);

  test('reschedule names the proposer from the viewer side', () {
    expect(asProvider('reschedule_by_provider'), 'Reschedule: You proposed');
    expect(asCustomer('reschedule_by_provider'), 'Reschedule: Provider proposed');
    expect(asProvider('reschedule_by_customer'), 'Reschedule: Customer proposed');
    expect(asCustomer('reschedule_by_customer'), 'Reschedule: You proposed');
  });

  test('cancellation names who cancelled', () {
    expect(asCustomer('cancelled_by_customer'), 'Cancelled by you');
    expect(asProvider('cancelled_by_customer'), 'Cancelled by customer');
    expect(asProvider('cancelled_by_provider'), 'Cancelled by you');
    expect(asCustomer('cancelled_by_provider'), 'Cancelled by provider');
  });

  test('other statuses and unknown values', () {
    expect(asCustomer('pending'), 'Pending Provider Response');
    expect(asProvider('completed'), 'Completed');
    expect(asCustomer('something_new'), 'something_new');
  });

  test('a proposal is only shown while a reschedule is open', () {
    expect(BookingLabels.showsProposal('reschedule_by_provider'), isTrue);
    expect(BookingLabels.showsProposal('reschedule_by_customer'), isTrue);
    expect(BookingLabels.showsProposal('cancelled_by_customer'), isFalse);
    expect(BookingLabels.showsProposal('confirmed'), isFalse);
  });
}
