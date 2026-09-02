// lib/core/models/notification_model.dart
import 'package:flutter/foundation.dart';

import '../utils/time_format.dart' show parseServerTime;

enum NotificationType { booking, payment, chat, reminder, system, other }

NotificationType _typeFromBackend(String? raw) {
  // Matches app/services/notify.py's type_ values across the whole
  // backend: "chat", "booking_new", "booking_status", "payment",
  // "general" (system/reminder use "general" too, distinguished by
  // title/body content rather than a dedicated type string).
  switch (raw) {
    case 'chat':
      return NotificationType.chat;
    case 'booking_new':
    case 'booking_status':
      return NotificationType.booking;
    case 'payment':
      return NotificationType.payment;
    case 'reminder':
      return NotificationType.reminder;
    case 'general':
      return NotificationType.system;
    default:
      return NotificationType.other;
  }
}

class AppNotification {
  final String id;
  final String title;
  final String message;
  final DateTime createdAt;
  final NotificationType type;
  final Map<String, dynamic> data; // deep-link navigation metadata
  bool read;
  bool archived; // client-side only — the backend has no archive
  // concept; this just hides a notification from view locally
  // without deleting it from history.

  AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.createdAt,
    required this.type,
    this.data = const {},
    this.read = false,
    this.archived = false,
  });

  /// Parses the REAL backend response shape (see
  /// app/routers/notifications.py's row_to_dict output): id, title,
  /// body, type, data, is_read, created_at — not the old mock
  /// shape's title/message/createdAt/read/archived.
  factory AppNotification.fromJson(Map<String, dynamic> json) {
    return AppNotification(
      id: json['id'].toString(),
      title: (json['title'] ?? '').toString(),
      message: (json['body'] ?? '').toString(),
      createdAt: parseServerTime(json['created_at']?.toString()) ??
          DateTime.now(),
      type: _typeFromBackend(json['type']?.toString()),
      data: json['data'] is Map
          ? Map<String, dynamic>.from(json['data'])
          : const {},
      read: json['is_read'] == true || json['is_read'] == 1,
    );
  }
}
