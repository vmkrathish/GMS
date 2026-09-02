import 'package:flutter/material.dart';

import '../services/refresh_bus.dart';
import 'refresh_spinner.dart';

class GMSHeader extends StatelessWidget {
  final BuildContext parentContext; // Needed for menu drawer
  final bool showSearch;
  final bool showMenu; // Only Home shows the hamburger menu icon

  const GMSHeader({
    super.key,
    required this.parentContext,
    this.showSearch = false,
    this.showMenu = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0xFF1565C0), // Dark Blue
            Color(0xFF42A5F5), // Light Blue
          ],
        ),
        borderRadius: BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            // Tapping the logo/app name refreshes whatever tab is
            // currently open, fetching everything fresh from the
            // database rather than relying on whatever was cached
            // when that screen last loaded. Feedback is just the
            // small spinner next to the title — no banner text.
            onTap: () => RefreshBus.bumpAll(),
            child: Row(
              children: [
                Image.asset('assets/images/gms_logo.png', height: 30),
                const SizedBox(width: 10),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: const [
                        Text(
                          'Get My Service',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 20,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 6),
                        RefreshSpinner(),
                      ],
                    ),
                    const Text(
                      'Any service. Any time. One app.',
                      style: TextStyle(fontSize: 11, color: Colors.white70),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (showMenu)
            IconButton(
              icon: const Icon(Icons.menu_rounded, color: Colors.white),
              onPressed: () {
                Scaffold.maybeOf(parentContext)?.openDrawer();
              },
            )
          else
            // Reserve the same footprint as the icon button so header
            // height/alignment stays identical across all 5 tabs.
            const SizedBox(width: 48, height: 48),
        ],
      ),
    );
  }
}
