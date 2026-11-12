// Run with:  flutter test test/chat_push_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:GMS/core/services/chat_push.dart';

void main() {
  test('chat pushes map to one tag per conversation (backend format)', () {
    expect(ChatPush.tagFor(7), 'gms-chat-7');
    expect(
        ChatPush.conversationTag(
            {'type': 'chat', 'partner_id': '7', 'conversation_tag': 'gms-chat-7'}),
        'gms-chat-7');
    // older backend without conversation_tag: derived from partner_id
    expect(ChatPush.conversationTag({'type': 'chat', 'partner_id': '9'}),
        'gms-chat-9');
    // two messages from the same chat → same slot; other chat → other slot
    final a1 = ChatPush.conversationTag({'type': 'chat', 'partner_id': '3'});
    final a2 = ChatPush.conversationTag({'type': 'chat', 'partner_id': '3'});
    final b = ChatPush.conversationTag({'type': 'chat', 'partner_id': '4'});
    expect(a1, a2);
    expect(a1 == b, isFalse);
  });

  test('non-chat pushes have no conversation slot and no receipt', () {
    expect(ChatPush.conversationTag({'type': 'booking', 'partner_id': '3'}),
        isNull);
    expect(ChatPush.messageId({'type': 'booking', 'message_id': '5'}), isNull);
    expect(ChatPush.conversationTag({'type': 'chat'}), isNull);
  });

  test('message id for the delivered receipt', () {
    expect(ChatPush.messageId({'type': 'chat', 'message_id': '42'}), 42);
    expect(ChatPush.messageId({'type': 'chat', 'message_id': ''}), isNull);
    expect(ChatPush.messageId({'type': 'chat', 'message_id': 'x'}), isNull);
    expect(ChatPush.messageId({'type': 'chat'}), isNull);
  });
}
