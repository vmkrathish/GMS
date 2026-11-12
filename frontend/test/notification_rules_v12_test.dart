// Run with:  flutter test test/notification_rules_v12_test.dart
// Pure rules for avatars and booking "View" notifications.
// The notifications themselves need a real Android device.
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/chat_push.dart';

void main() {
  final chat = {'type': 'chat', 'partner_id': '7', 'message_id': '42'};

  test('avatar url: absolute kept, server path joined, else initial', () {
    const root = 'https://gms.example';
    expect(ChatPush.avatarUrl({'sender_avatar': '/static/avatars/a.jpg'}, root),
        'https://gms.example/static/avatars/a.jpg');
    expect(ChatPush.avatarUrl({'sender_avatar': 'https://cdn.x/a.png'}, root),
        'https://cdn.x/a.png');
    expect(ChatPush.avatarUrl({'sender_avatar': ''}, root), isNull);
    expect(ChatPush.avatarUrl({}, root), isNull);
    expect(ChatPush.avatarUrl({'sender_avatar': 'javascript:x'}, root), isNull);
  });

  test('booking events: own slot per notification, View target', () {
    final d = {'type': 'booking', 'screen': 'booking', 'booking_id': '9',
               'notif_id': '77'};
    expect(ChatPush.isBookingEvent(d), isTrue);
    expect(ChatPush.isBookingEvent(chat), isFalse);
    expect(ChatPush.eventTag(d), 'gms-n-77'); // = backend notify.py tag
    expect(ChatPush.notifId(d), 77);
    expect(ChatPush.bookingId(d), 9);
    expect(ChatPush.viewActionId, 'gms_view');
  });
}

// V14: the notification Reply/Retry actions were removed.
