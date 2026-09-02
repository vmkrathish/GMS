// lib/core/services/notification_service.dart
//
// Real backend-backed notification service — replaces the old
// hardcoded mock version. That version only ever seeded fake data
// and computed the unread badge the FIRST time fetchNotifications()
// was called (i.e. only once someone opened the Notifications
// screen), which is exactly why the drawer badge showed nothing on
// first open and only "caught up" after visiting the screen once.
// This version fetches the real unread count eagerly (see
// refreshUnreadCount, called from main.dart on app start — same
// pattern as ChatBadgeService), so the badge is correct from the
// very first time the menu opens.
import 'package:flutter/foundation.dart';

import '../api/notification_api.dart';
import 'notification_model.dart';

class NotificationService {
  NotificationService._private();
  static final NotificationService _instance = NotificationService._private();
  factory NotificationService() => _instance;

  final ValueNotifier<int> unreadCount = ValueNotifier<int>(0);

  final List<AppNotification> _store = [];
  String? _nextCursor;
  bool _hasMore = true;

  AppNotification? _findById(String id) {
    for (final n in _store) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Cheap, fast — just the count, not the full list. Call this
  /// eagerly (app start, after login, app resume) so the badge is
  /// never stale waiting for someone to open the full screen.
  Future<void> refreshUnreadCount() async {
    final res = await NotificationApi.unreadCount();
    if (res.success && res.data is Map && res.data['success'] == true) {
      unreadCount.value = (res.data['unread'] as num?)?.toInt() ?? 0;
    }
  }

  /// First page, newest first. Resets any previous pagination state
  /// — call this on initial screen load / pull-to-refresh, not for
  /// "load more" (use loadMore for that).
  Future<List<AppNotification>> fetchNotifications() async {
    final res = await NotificationApi.list();
    if (!res.success || res.data is! Map) return [];

    final list = (res.data['notifications'] as List?) ?? [];
    _store
      ..clear()
      ..addAll(list.map((e) => AppNotification.fromJson(
          Map<String, dynamic>.from(e as Map))));
    _nextCursor = res.data['next_cursor'] as String?;
    _hasMore = res.data['has_more'] == true;

    await refreshUnreadCount();
    return List<AppNotification>.from(_store);
  }

  bool get hasMore => _hasMore;

  /// Appends the next 20 to the existing list — returns the FULL
  /// list so far (existing + newly loaded), matching fetchNotifications'
  /// return contract so callers don't need two different code paths.
  Future<List<AppNotification>> loadMore() async {
    if (!_hasMore || _nextCursor == null) return List.from(_store);

    final res = await NotificationApi.list(cursor: _nextCursor);
    if (!res.success || res.data is! Map) return List.from(_store);

    final list = (res.data['notifications'] as List?) ?? [];
    _store.addAll(list.map((e) => AppNotification.fromJson(
        Map<String, dynamic>.from(e as Map))));
    _nextCursor = res.data['next_cursor'] as String?;
    _hasMore = res.data['has_more'] == true;

    return List<AppNotification>.from(_store);
  }

  Future<void> markAllRead() async {
    final res = await NotificationApi.markAllRead();
    if (res.success) {
      for (var n in _store) {
        n.read = true;
      }
      unreadCount.value = 0;
    }
  }

  Future<void> markRead(String id) async {
    final idInt = int.tryParse(id);
    if (idInt == null) return;
    final res = await NotificationApi.markRead(idInt);
    if (res.success) {
      final n = _findById(id);
      if (n != null && !n.read) {
        n.read = true;
        // Update immediately from local state rather than waiting
        // on a full refetch — this is the actual fix for "badge
        // doesn't update until you leave and come back": the count
        // now changes the instant a notification is opened, not on
        // the next screen visit.
        if (unreadCount.value > 0) unreadCount.value--;
      }
    }
  }

  Future<void> markUnread(String id) async {
    // No backend endpoint for this (the spec never asked for it) —
    // kept as a local-only UI toggle so the existing "mark unread"
    // menu option doesn't crash; it won't survive a refresh.
    final n = _findById(id);
    if (n != null && n.read) {
      n.read = false;
      unreadCount.value++;
    }
  }

  Future<void> deleteNotification(String id) async {
    final idInt = int.tryParse(id);
    if (idInt == null) return;
    final res = await NotificationApi.delete(idInt);
    if (res.success) {
      final wasUnread =
          _findById(id)?.read == false;
      _store.removeWhere((x) => x.id == id);
      if (wasUnread && unreadCount.value > 0) unreadCount.value--;
    }
  }

  Future<void> archiveNotification(String id) async {
    // Client-side only — see AppNotification.archived.
    final n = _findById(id);
    if (n != null) n.archived = true;
  }

  /// Call on logout so a stale badge doesn't flash for the next
  /// account in the same browser tab — same pattern as
  /// ChatBadgeService.reset().
  void reset() {
    _store.clear();
    _nextCursor = null;
    _hasMore = true;
    unreadCount.value = 0;
  }
}
