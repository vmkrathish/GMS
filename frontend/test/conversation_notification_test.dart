// Run with:  flutter test test/conversation_notification_test.dart
// Pure rules behind the Android conversation notification (grouping,
// lines, reply target). The notification UI itself needs a device.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/chat_push.dart';

Map<String, dynamic> push(List<Map<String, String>> recent,
        {String partner = '7', String title = 'Asha', String body = 'last'}) =>
    {
      'type': 'chat',
      'partner_id': partner,
      'conversation_tag': 'gms-chat-$partner',
      'title': title,
      'body': body,
      'recent': jsonEncode(recent),
    };

void main() {
  test('expanded lines: every unread message, oldest first, with times', () {
    final lines = ChatPush.recentLines(push([
      {'t': 'one', 'ts': '2026-11-10T10:00:00'},
      {'t': 'two', 'ts': '2026-11-10T10:01:00'},
      {'t': 'three', 'ts': '2026-11-10T10:02:00'},
    ]));
    expect(lines.map((l) => l.text), ['one', 'two', 'three']);
    expect(lines.first.time.isBefore(lines.last.time), isTrue);
  });

  test('never more than 5 lines (keeps the newest)', () {
    final many = [for (var i = 0; i < 8; i++) {'t': 'm$i', 'ts': ''}];
    expect(ChatPush.recentLines(push(many)).map((l) => l.text),
        ['m3', 'm4', 'm5', 'm6', 'm7']);
  });

  test('falls back to the body when recent is missing or broken', () {
    final d = push(const [], body: 'only this');
    expect(ChatPush.recentLines(d).single.text, 'only this');
    d['recent'] = '{not json';
    expect(ChatPush.recentLines(d).single.text, 'only this');
    d.remove('recent');
    expect(ChatPush.recentLines(d).single.text, 'only this');
  });

  test('same person = same slot; different people = separate slots', () {
    final a1 = push([{'t': 'x', 'ts': ''}], partner: '3');
    final a2 = push([{'t': 'y', 'ts': ''}], partner: '3');
    final b = push([{'t': 'z', 'ts': ''}], partner: '4');
    expect(ChatPush.conversationTag(a1), ChatPush.conversationTag(a2));
    expect(ChatPush.conversationTag(a1) == ChatPush.conversationTag(b), isFalse);
  });

  test('the conversation belongs to the sender', () {
    expect(ChatPush.partnerId(push(const [], partner: '42')), 42);
    expect(ChatPush.partnerId({'type': 'booking', 'partner_id': '42'}), isNull);
    expect(ChatPush.senderName(push(const [], title: 'Bala')), 'Bala');
    expect(ChatPush.senderName({'type': 'chat'}), 'GMS');
  });
}
