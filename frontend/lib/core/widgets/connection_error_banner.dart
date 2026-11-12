// ─────────────────────────────────────────────
// core/widgets/connection_error_banner.dart
//
// The red error box used on Sign In / Sign Up, plus an optional
// "Try again" action for connection / server problems.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';

class ConnectionErrorBanner extends StatelessWidget {
  final String message;

  /// When non-null a "Try again" button is shown.
  final VoidCallback? onRetry;

  const ConnectionErrorBanner({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.red.shade50,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message,
              style: TextStyle(color: Colors.red.shade700, fontSize: 13)),
          if (onRetry != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Try again'),
                style: TextButton.styleFrom(
                    foregroundColor: Colors.red.shade700),
              ),
            ),
        ],
      ),
    );
  }
}
