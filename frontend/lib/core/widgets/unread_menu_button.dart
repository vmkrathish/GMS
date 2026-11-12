// ─────────────────────────────────────────────
// core/widgets/unread_menu_button.dart
//
// The header's three-line menu button with a solid red dot while there is
// at least one unread IN-APP notification (bookings, reschedules,
// cancellations, payments, service news — never chat, which is push-only).
// A dot, not a number: it stays readable whether there are 1 or 100. The
// number lives next to "Notifications" in the side menu (99+ cap).
// The dot goes away only when the server's unread count reaches 0, i.e.
// every notification has been marked read under the existing read rules.
// ─────────────────────────────────────────────
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

class UnreadMenuButton extends StatelessWidget {
  final ValueListenable<int> unread;
  final VoidCallback onPressed;
  final Color color;

  const UnreadMenuButton({
    super.key,
    required this.unread,
    required this.onPressed,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: unread,
      builder: (_, n, __) => IconButton(
        tooltip: n > 0 ? 'Menu — unread notifications' : 'Menu',
        onPressed: onPressed,
        icon: Stack(
          clipBehavior: Clip.none,
          children: [
            Icon(Icons.menu_rounded, color: color),
            if (n > 0)
              Positioned(
                right: -2,
                top: -2,
                child: Container(
                  key: const ValueKey('menu-unread-dot'),
                  width: 11,
                  height: 11,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE53935), // solid red
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
