import 'package:flutter/material.dart';

import 'core/theme/app_theme.dart';
import 'core/widgets/app_drawer.dart';
import 'core/widgets/bottom_nav.dart';
import 'core/widgets/offline_overlay.dart';
import 'core/currency/currencies_format.dart';
import 'core/services/chat_badge_service.dart';
import 'core/services/booking_badge_service.dart';
import 'core/models/notification_service.dart';
import 'core/services/fcm_service.dart';
import 'core/services/refresh_bus.dart';

import 'presentation/screens/home_screen.dart';
import 'presentation/screens/map_screen.dart';
import 'presentation/screens/you_screen.dart';
import 'presentation/screens/payments_screen.dart';
import 'presentation/screens/bookings_screen.dart';
import 'presentation/screens/chat_screen.dart';
import 'presentation/screens/settings_screen.dart';
import 'presentation/screens/intro_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await CurrencyFormatter.load();
  runApp(const GMSApp());
}

class GMSApp extends StatelessWidget {
  const GMSApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GMS - Get My Service',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      navigatorKey: FcmService().navigatorKey,

      // Entry screen
      home: const IntroScreen(),

      // Optional routes (future-proof)
      routes: {
        '/main': (_) => const GMSMainPage(),
        '/settings': (_) => const SettingsScreen(),
      },
    );
  }
}

class GMSMainPage extends StatefulWidget {
  const GMSMainPage({super.key});

  @override
  State<GMSMainPage> createState() => _GMSMainPageState();
}

class _GMSMainPageState extends State<GMSMainPage> {
  int _currentIndex = 0;

  final List<Widget> _screens = const [
    HomeScreen(),
    MapScreen(),
    YouScreen(),
    PaymentsScreen(),
    BookingsScreen(),
    ChatScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Keep the Chat tab's unread badge fresh the whole time the app
    // is open — WhatsApp/Instagram style, no need to open Chat first.
    ChatBadgeService.startPolling();
    // Same pattern for the Bookings tab badge - counts bookings
    // that need this user's response right now (a new request, a
    // reschedule proposal, an advance payment due).
    BookingBadgeService.startPolling();
    // Same fix for the Notifications badge — fetched eagerly here
    // rather than only when the Notifications screen itself is
    // opened. That lazy-only approach was the actual cause of the
    // badge showing nothing on first menu open and only "catching
    // up" after a visit to the screen.
    NotificationService().refreshUnreadCount();
    // Registers this device for push (Android/Web — iOS stays
    // paused, see fcm_service.dart's header). Called here rather
    // than at app startup because it needs the auth token, which
    // only exists once GMSMainPage has actually been reached.
    FcmService().initialize();
  }

  @override
  void dispose() {
    ChatBadgeService.stopPolling();
    BookingBadgeService.stopPolling();
    super.dispose();
  }

  void _onTabTapped(int index) {
    final wasAlreadyActive = index == _currentIndex;
    setState(() {
      _currentIndex = index;
    });
    if (index == 5) {
      // Opened Chat — refresh immediately rather than waiting for
      // the next poll tick, so the badge clears the moment threads
      // are actually read.
      ChatBadgeService.refresh();
    }
    if (index == 4) {
      // Opened Bookings — same immediate-refresh reasoning.
      BookingBadgeService.refresh();
    }
    if (wasAlreadyActive) {
      // Tapping the tab you're already on reloads its data fresh
      // from the database, rather than doing nothing.
      switch (index) {
        case 0:
          RefreshBus.bumpHome();
          break;
        case 1:
          RefreshBus.bumpMap();
          break;
        case 2:
          RefreshBus.bumpProfile();
          break;
        case 3:
          RefreshBus.bumpPayments();
          break;
        case 4:
          RefreshBus.bumpBookings();
          break;
        case 5:
          RefreshBus.bumpChat();
          break;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // Drawer
      drawer: const AppDrawer(),

      // Main content
      body: SafeArea(child: OfflineOverlay(child: _screens[_currentIndex])),

      // Bottom Navigation
      bottomNavigationBar: BottomNavBar(
        currentIndex: _currentIndex,
        onTabTapped: _onTabTapped,
      ),
    );
  }
}
