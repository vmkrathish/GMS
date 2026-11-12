import 'package:flutter/material.dart';

import '../services/chat_badge_service.dart';
import '../services/booking_badge_service.dart';

class BottomNavBar extends StatelessWidget {
  final int currentIndex;
  final Function(int) onTabTapped;

  const BottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onTabTapped,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1565C0), // Dark Blue
            Color(0xFF42A5F5), // Light Blue
          ],
        ),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(20),
        ),
        child: BottomNavigationBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          currentIndex: currentIndex,
          onTap: onTabTapped,
          selectedItemColor: Colors.white,
          unselectedItemColor: Colors.white70,
          type: BottomNavigationBarType.fixed,
          items: [
            const BottomNavigationBarItem(
              icon: Icon(Icons.home_outlined),
              label: 'Home',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.map_outlined),
              label: 'Map',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.person_outline),
              label: 'You',
            ),
            const BottomNavigationBarItem(
              icon: Icon(Icons.account_balance_wallet_outlined),
              label: 'Payments',
            ),
            BottomNavigationBarItem(
              icon: ValueListenableBuilder<int>(
                valueListenable: BookingBadgeService.needsAttention,
                builder: (context, count, _) {
                  return Badge(
                    isLabelVisible: count > 0,
                    label: Text(count > 99 ? '99+' : '$count'),
                    backgroundColor: Colors.redAccent,
                    child: const Icon(Icons.event_note_outlined),
                  );
                },
              ),
              label: 'Bookings',
            ),
            BottomNavigationBarItem(
              // WhatsApp/Instagram-style small red circle showing how
              // many DIFFERENT conversations have unread messages —
              // not the total message count.
              icon: ValueListenableBuilder<int>(
                valueListenable: ChatBadgeService.unreadThreads,
                builder: (context, count, _) {
                  return Badge(
                    isLabelVisible: count > 0,
                    label: Text(count > 99 ? '99+' : '$count'),
                    backgroundColor: Colors.redAccent,
                    child: const Icon(Icons.chat_bubble_outline),
                  );
                },
              ),
              label: 'Chat',
            ),
          ],
        ),
      ),
    );
  }
}
