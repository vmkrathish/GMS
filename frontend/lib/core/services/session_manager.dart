// ─────────────────────────────────────────────
// core/services/session_manager.dart
//
// Single source of truth for "who is logged in".
//  • Persists JWT + user profile in SharedPreferences
//  • App startup: SessionManager.isLoggedIn() gates
//    Home vs Login (see intro_screen.dart)
// ─────────────────────────────────────────────
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_service.dart';
import 'chat_badge_service.dart';
import 'booking_badge_service.dart';
import '../models/notification_service.dart';
import 'fcm_service.dart';
import '../../presentation/screens/you_screen.dart' show userProfile;

class SessionManager {
  static const _userKey = 'gms_user';

  /// Save session after successful login/signup.
  static Future<void> saveSession({
    required String token,
    required Map<String, dynamic> user,
  }) async {
    await ApiService.saveToken(token);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user));
  }

  /// Update just the cached profile (after profile edits).
  static Future<void> saveUser(Map<String, dynamic> user) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_userKey, jsonEncode(user));
  }

  static Future<Map<String, dynamic>?> getUser() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_userKey);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw));
    } catch (_) {
      return null;
    }
  }

  /// Logged in = we hold a JWT.
  static Future<bool> isLoggedIn() async {
    final token = await ApiService.getToken();
    return token != null && token.isNotEmpty;
  }

  /// Full logout: clears token + cached profile, AND resets the
  /// shared in-memory profile notifier. Without this reset, any
  /// local-only field left in `userProfile` (an avatar preview,
  /// a name typed but not yet saved, etc.) would silently carry
  /// over and be shown to the NEXT person who logs in on this same
  /// browser tab — this is exactly what caused the avatar to
  /// "leak" from one account to another.
  static Future<void> logout() async {
    // Must happen BEFORE clearToken() below — deactivating this
    // device's push token is itself an authenticated call. Only
    // this one device's token is touched (see notifications.py's
    // remove_push_token, scoped to token+user_id) — any other
    // device this account is logged into keeps receiving push.
    await FcmService().deactivateCurrentToken();

    await ApiService.clearToken();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_userKey);
    ChatBadgeService.reset();
    BookingBadgeService.reset();
    NotificationService().reset();

    userProfile.value = {
      'name': '',
      'email': '',
      'phone': '',
      'dialCode': '+91',
      'location': '',
      'rating': '0.0',
      'avatar': null,
      'webImageBytes': null,
      'avatarUrl': null,
      'country': 'India',
      'addressLine1': '',
      'areaStreetVillage': '',
      'landmark': '',
      'pincode': '',
      'city': '',
      'state': 'TAMIL NADU',
      'latitude': null,
      'longitude': null,
      'primaryService': {'name': '', 'charge': '', 'type': 'per day'},
      'otherServices': <Map<String, String>>[],
    };
  }
}
