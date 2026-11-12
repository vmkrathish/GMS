// ─────────────────────────────────────────────
// core/services/device_identity.dart
//
// A random, persistent id for THIS install (phone app or browser
// profile). It is what lets the server keep exactly one active push
// token per (user, device), and what makes "another account just took
// over this device" detectable — see notifications.py's
// register_push_token.
//
// Minted once, stored in SharedPreferences. SessionManager.logout()
// removes individual keys (never prefs.clear()), so this survives
// logout/login — which is the point: the device keeps its identity
// across accounts. Clearing site data / reinstalling mints a new one.
// ─────────────────────────────────────────────
import 'dart:math';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:shared_preferences/shared_preferences.dart';

class DeviceIdentity {
  DeviceIdentity._();

  static const _key = 'gms_device_id';

  /// Must stay in sync with _DEVICE_ID_RE in backend notifications.py
  /// (8-128 chars of letters, digits, '-' or '_').
  static final RegExp _valid = RegExp(r'^[A-Za-z0-9_\-]{8,128}$');

  static String? _cached;

  /// The persistent device id (created on first use).
  static Future<String> deviceId() async {
    final cached = _cached;
    if (cached != null) return cached;

    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_key);
    if (id == null || !_valid.hasMatch(id)) {
      id = randomId();
      await prefs.setString(_key, id);
    }
    _cached = id;
    return id;
  }

  /// Cryptographically random hex id. Also used for Idempotency-Key.
  static String randomId([int bytes = 16]) {
    final rnd = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < bytes; i++) {
      sb.write(rnd.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  @visibleForTesting
  static void resetCacheForTests() => _cached = null;
}
