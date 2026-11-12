// ─────────────────────────────────────────────
// core/services/delivery_receipts.dart
//
// "Delivered" receipt: the recipient's DEVICE tells the server it got a
// chat push (two grey ticks for the sender). Called from the FCM handlers
// — foreground (onMessage) and background (firebaseMessagingBackgroundHandler,
// which runs in a separate isolate, hence no ApiService/UI dependencies).
//
// Not a guarantee for every case: Android does not run the background
// handler for an app the user FORCE-STOPPED (FCM isn't delivered to it at
// all), and an ack that fails offline is not retried here. Those messages
// become "delivered" the next time the app loads the chat list
// (GET /api/chats marks everything waiting for this user as delivered).
// ─────────────────────────────────────────────
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../config/api_config.dart';
import '../config/api_endpoints.dart';
import 'api_service.dart' show ApiService;
import 'chat_push.dart';

class DeliveryReceipts {
  /// Never throws. Returns true when the server accepted the ack.
  static Future<bool> ackFromPush(Map<String, dynamic> data) async {
    final id = ChatPush.messageId(data);
    if (id == null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      // The background isolate may hold a stale cache — re-read the token
      // the UI isolate saved at login.
      await prefs.reload();
      final token = prefs.getString(ApiService.tokenKey);
      if (token == null || token.isEmpty) return false; // signed out
      final res = await http
          .post(
            Uri.parse(ApiConfig.baseUrl + ApiEndpoints.chatDeliveredReceipts),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'message_ids': [id]}),
          )
          .timeout(const Duration(seconds: 10));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
