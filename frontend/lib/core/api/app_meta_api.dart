// ─────────────────────────────────────────────
// core/api/app_meta_api.dart — small app-level metadata calls that
// don't belong under /api (matching the backend's root-level
// /health and /meta/current-year endpoints, not routed through any
// versioned router).
// ─────────────────────────────────────────────
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../config/api_config.dart';

class AppMetaApi {
  /// The real current year, from the server's clock — never trust a
  /// device's local clock for something like a copyright range,
  /// since it can be set wrong (or wrong on purpose). Returns null on
  /// any failure; callers should fall back to a sensible default
  /// rather than show nothing.
  static Future<int?> getCurrentYear() async {
    try {
      final res = await http
          .get(Uri.parse('${ApiConfig.serverRoot}/meta/current-year'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is Map && data['success'] == true && data['year'] is int) {
        return data['year'] as int;
      }
    } catch (_) {
      // network hiccup — caller falls back
    }
    return null;
  }
}
