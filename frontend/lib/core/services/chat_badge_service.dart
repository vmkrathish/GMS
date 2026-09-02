// ─────────────────────────────────────────────
// core/services/chat_badge_service.dart
//
// WhatsApp/Instagram-style unread badge: counts DISTINCT
// CONVERSATIONS that have at least one unread message — not the
// total number of unread messages. Ten unread messages from one
// person = 1. Ten different people with one unread each = 10.
//
// Pure frontend aggregation over data the chat API already
// returns (each conversation's `unread_count`) — no backend or
// database changes needed.
// ─────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/foundation.dart';

import '../api/chat_api.dart';

class ChatBadgeService {
  static final ValueNotifier<int> unreadThreads = ValueNotifier<int>(0);

  static Timer? _poller;

  /// Fetches the conversation list and updates the badge count.
  /// Safe to call anywhere, anytime (login, app resume, after
  /// opening/closing a chat, etc).
  static Future<void> refresh() async {
    final res = await ChatApi.getConversations();
    if (!res.success || res.data is! Map) return;
    final list = res.data['conversations'];
    if (list is! List) return;

    int count = 0;
    for (final raw in list) {
      final c = Map<String, dynamic>.from(raw as Map);
      final unread = int.tryParse('${c['unread_count'] ?? 0}') ?? 0;
      if (unread > 0) count++;
    }
    unreadThreads.value = count;
  }

  /// Call once after login / app start. Keeps the badge fresh even
  /// if the person never opens the Chat tab — same as WhatsApp
  /// showing a live badge on the app icon without opening the app.
  static void startPolling({Duration every = const Duration(seconds: 20)}) {
    _poller?.cancel();
    refresh();
    _poller = Timer.periodic(every, (_) => refresh());
  }

  static void stopPolling() {
    _poller?.cancel();
    _poller = null;
  }

  /// Call on logout so a stale count doesn't flash for the next
  /// account in the same browser tab.
  static void reset() {
    stopPolling();
    unreadThreads.value = 0;
  }
}
