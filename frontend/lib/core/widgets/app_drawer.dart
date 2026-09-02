import 'package:flutter/material.dart';

import '../../presentation/screens/about_gms_screen.dart';
import '../../presentation/screens/help_support_screen.dart';
import '../../presentation/screens/notifications_screen.dart';
import '../../presentation/screens/settings_screen.dart';
import '../../core/models/notification_service.dart';
import '../../core/services/session_manager.dart';
import '../../presentation/screens/auth/login_screen.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ---------------- HEADER ----------------
            DrawerHeader(
              decoration: const BoxDecoration(color: Colors.white),
              margin: EdgeInsets.zero,
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Image.asset('assets/images/gms_logo.png', height: 40),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FutureBuilder<Map<String, dynamic>?>(
                      future: SessionManager.getUser(),
                      builder: (context, snap) {
                        final name = snap.data?['name']?.toString() ?? '';
                        return Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name.isNotEmpty ? 'Hi, $name 👋' : 'Menu',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 19,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                            ),
                            if (name.isNotEmpty)
                              Text(
                                snap.data?['phone']?.toString() ?? '',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.black45),
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            const Divider(height: 1),

            // ---------------- NOTIFICATIONS ----------------
            _drawerItem(
              context,
              icon: Icons.notifications_none,
              titleWidget: ValueListenableBuilder<int>(
                valueListenable: NotificationService().unreadCount,
                builder: (context, unread, _) {
                  return Row(
                    children: [
                      const Text('Notifications'),
                      const SizedBox(width: 8),
                      if (unread > 0)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.red,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            unread > 99 ? '99+' : unread.toString(),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const NotificationsScreen(),
                  ),
                );
              },
            ),

            // ---------------- SETTINGS ----------------
            _drawerItem(
              context,
              icon: Icons.settings_outlined,
              title: 'Settings',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),

            // ---------------- HELP ----------------
            _drawerItem(
              context,
              icon: Icons.help_outline,
              title: 'Help & Support',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const HelpSupportScreen()),
                );
              },
            ),

            // ---------------- ABOUT ----------------
            _drawerItem(
              context,
              icon: Icons.info_outline,
              title: 'About GMS',
              onTap: () {
                Navigator.pop(context);
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AboutGmsScreen()),
                );
              },
            ),

            const Spacer(),

            const Divider(height: 1),

            // ---------------- LOGOUT ----------------
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.red),
              title: const Text('Logout', style: TextStyle(color: Colors.red)),
              onTap: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16)),
                    title: const Text('Logout?'),
                    content:
                        const Text('You will need to sign in again to use GMS.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Logout',
                            style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirm != true) return;
                await SessionManager.logout();
                if (!context.mounted) return;
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const LoginScreen()),
                  (route) => false,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- COMMON TILE ----------------
  Widget _drawerItem(
    BuildContext context, {
    required IconData icon,
    String? title,
    Widget? titleWidget,
    required VoidCallback onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: Colors.blue[700]),
      title:
          titleWidget ??
          Text(
            title ?? '',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
      onTap: onTap,
    );
  }
}
