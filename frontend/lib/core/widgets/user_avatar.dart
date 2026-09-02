// ─────────────────────────────────────────────
// core/widgets/user_avatar.dart
//
// One avatar widget for the whole app:
//  • avatarUrl present  → network image
//  • no image / failed  → first letter of the name (e.g. Rathish → R)
// Used in Home recommendations, Bookings, Chat list & thread.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';

import '../config/api_config.dart';
import '../theme/app_theme.dart';

class UserAvatar extends StatelessWidget {
  final String? avatarUrl;
  final String name;
  final double radius;
  final Color? backgroundColor;
  final Color? textColor;

  const UserAvatar({
    super.key,
    required this.name,
    this.avatarUrl,
    this.radius = 24,
    this.backgroundColor,
    this.textColor,
  });

  String get _initial {
    final t = name.trim();
    return t.isEmpty ? '?' : t[0].toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final bg = backgroundColor ?? Colors.blue.shade100;
    final fg = textColor ?? AppTheme.primaryBlue;
    // Resolves a relative server path (e.g. "/static/avatars/x.png")
    // against whatever host the app is CURRENTLY talking to. Without
    // this, an image uploaded under a different server address
    // (previous WiFi, previous port, before a redeploy) would break
    // permanently even though the file itself never moved.
    final url = ApiConfig.resolveMediaUrl(avatarUrl);
    final hasImage = url != null;

    return CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      foregroundImage: hasImage ? NetworkImage(url) : null,
      // onForegroundImageError keeps the initial visible if the URL breaks
      onForegroundImageError: hasImage ? (_, __) {} : null,
      child: Text(
        _initial,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: radius * 0.72,
          color: fg,
        ),
      ),
    );
  }
}

/// Read-only full-screen view of ANOTHER person's profile photo —
/// tap to dismiss, no edit/remove/download controls. Used wherever
/// a photo is shown but doesn't belong to the current account
/// (Home recommendations, Bookings, Chat, Public Profile).
/// Does nothing if there's no real photo to show.
Future<void> showReadOnlyAvatarViewer(
  BuildContext context, {
  required String? avatarUrl,
  required String name,
}) async {
  final url = ApiConfig.resolveMediaUrl(avatarUrl);
  if (url == null) return;

  await showDialog(
    context: context,
    barrierColor: Colors.black87,
    builder: (ctx) => GestureDetector(
      onTap: () => Navigator.of(ctx).pop(),
      child: Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Stack(
          alignment: Alignment.center,
          children: [
            InteractiveViewer(
              minScale: 0.8,
              maxScale: 4,
              child: Hero(
                tag: 'avatar_$url',
                child: ClipOval(
                  child: Image.network(
                    url,
                    width: 280,
                    height: 280,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => CircleAvatar(
                      radius: 140,
                      backgroundColor: Colors.blue.shade100,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : '?',
                        style: const TextStyle(
                            fontSize: 90,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryBlue),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 40,
              right: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 28),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
