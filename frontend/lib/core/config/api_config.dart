// ═══════════════════════════════════════════════════════════
//  api_config.dart — THE ONE PLACE to switch GMS between
//  LOCAL (developing on your own laptop) and ONLINE (hosted,
//  e.g. Render/Railway/your own server) mode.
//
//  HOW TO USE — flip the ONE line marked "THE SWITCH" below:
//    Developing locally  → _isOnline = false  (already set)
//    Ready to deploy      → comment the "false" line, uncomment
//                           the "true" line right under it,
//                           make sure _onlineUrl below is your
//                           real deployed URL, save, push.
//
//  Every screen, every API call, every image URL in this whole
//  app reads from ApiConfig.baseUrl / ApiConfig.serverRoot below
//  — nothing else in the codebase should ever hardcode an IP,
//  port, or domain. Change it here once, it's reflected
//  everywhere automatically.
//
//  ⚠️  THIS is the switch to flip if you want your local Flutter
//  app to talk to your already-deployed Render backend. You do NOT
//  need to run a backend locally for that, and you do NOT need to
//  touch backend/app/core/env_config.py — that file only affects a
//  backend running on your own machine, which is a separate,
//  independent thing from Render's own copy.
// ═══════════════════════════════════════════════════════════
import 'package:flutter/foundation.dart';

class ApiConfig {
  // ───────────────────────────────────────────────────────
  // 🔀 THE SWITCH — exactly one of these two lines should be
  // active at a time. To go LIVE: comment out the LOCAL line,
  // remove the "//" from the ONLINE line below it, save, push.
  // To go back to local dev: swap them back.
  // (If you ever leave both active by mistake, Dart will refuse
  // to compile with a "duplicate definition" error — so it's
  // impossible to accidentally ship pointing at the wrong one.)
  // ───────────────────────────────────────────────────────
  //static const bool _isOnline = false; // ← LOCAL (dev on your laptop)
   static const bool _isOnline = true; // ← ONLINE (hosted, e.g. Render)

  static const String _localIp = "192.168.29.145"; // <- YOUR machine's LAN IP
  static const int _localPort = 5001;
  static const String _onlineUrl = "https://gms-343g.onrender.com";

  /// Everything below this line derives from the two toggles
  /// above — don't hand-edit past here.

  static String get baseUrl {
    if (_isOnline) return "$_onlineUrl/api";
    if (kIsWeb) return "http://localhost:$_localPort/api";
    // Android emulator reaches host machine via 10.0.2.2:
    // return "http://10.0.2.2:$_localPort/api";
    return "http://$_localIp:$_localPort/api";
  }

  /// Same host as [baseUrl] but WITHOUT the /api suffix — the root
  /// that /static/... files are served from.
  static String get serverRoot =>
      baseUrl.endsWith('/api') ? baseUrl.substring(0, baseUrl.length - 4) : baseUrl;

  /// Resolves any stored media path (avatar_url, etc.) into a URL
  /// that's actually loadable RIGHT NOW, regardless of where the
  /// server happens to be running today:
  ///  - null/empty            → null (caller shows a fallback)
  ///  - already a full URL    → used as-is (e.g. external avatars
  ///                            like pravatar.cc, or Cloudinary later)
  ///  - a relative server path (e.g. "/static/avatars/x.png")
  ///                          → prefixed with the CURRENT [serverRoot]
  ///
  /// This is what makes uploaded images keep working after the
  /// backend's address changes (different WiFi, different port, a
  /// real domain later) — old absolute URLs baked with a stale host
  /// used to break permanently even though the file never moved.
  static String? resolveMediaUrl(String? path) {
    final p = (path ?? '').trim();
    if (p.isEmpty || p == 'null') return null;
    if (p.startsWith('http://') || p.startsWith('https://')) return p;
    return '$serverRoot${p.startsWith('/') ? '' : '/'}$p';
  }

  /// Request timeout for all API calls.
  static const Duration timeout = Duration(seconds: 15);
}
