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
import 'core/services/api_service.dart';
import 'core/services/session_manager.dart';
import 'core/services/app_visibility.dart';
import 'core/services/app_navigation.dart';

import 'presentation/screens/home_screen.dart';
import 'presentation/screens/map_screen.dart';
import 'presentation/screens/you_screen.dart';
import 'presentation/screens/payments_screen.dart';
import 'presentation/screens/bookings_screen.dart';
import 'presentation/screens/chat_screen.dart';
import 'presentation/screens/settings_screen.dart';
import 'presentation/screens/intro_screen.dart';
import 'presentation/screens/auth/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await CurrencyFormatter.load();
  ApiService.onSessionInvalid = _onSessionRejected;
  AppVisibility.init();
  runApp(const GMSApp());
}

/// The server no longer accepts the saved token (expired after
/// ACCESS_TOKEN_EXPIRE_MINUTES, account deactivated, JWT secret rotated).
/// Previously every screen just kept failing; now the session is cleared
/// once and the person is taken back to Sign In with an explanation.
Future<void> _onSessionRejected(String rejectedToken) async {
  final ended = await SessionManager.endRejectedSession(rejectedToken);
  if (!ended) return;
  FcmService().navigatorKey.currentState?.pushAndRemoveUntil(
        MaterialPageRoute(
            builder: (_) => const LoginScreen(
                notice: 'Your session has expired. Please sign in again.')),
        (route) => false,
      );
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

  /// null until checked; the main shell never runs without a session
  /// (there is no "demo" way in any more — see LoginScreen).
  bool? _signedIn;

  void _onTabRequest() {
    final t = AppNavigation.tabRequest.value;
    if (t == null || !mounted) return;
    AppNavigation.tabRequest.value = null;
    _onTabTapped(t);
  }

  @override
  void initState() {
    super.initState();
    AppNavigation.tabRequest.addListener(_onTabRequest);
    // A notification may have asked for a tab before this page existed.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onTabRequest());
    _startIfSignedIn();
  }

  Future<void> _startIfSignedIn() async {
    final ok = await SessionManager.isLoggedIn();
    if (!mounted) return;
    if (!ok) {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
      return;
    }
    setState(() => _signedIn = true);
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
    // Starts push (Android/Web — iOS stays paused, see
    // fcm_service.dart's header) and registers this device for the
    // signed-in user. Called here rather than at app startup because it
    // needs the auth token. Safe on every build of this page: infra
    // starts once, registration is deduplicated per session, and later
    // logins re-register via SessionManager.saveSession().
    FcmService().start();
  }

  @override
  void dispose() {
    AppNavigation.tabRequest.removeListener(_onTabRequest);
    if (_signedIn == true) {
      ChatBadgeService.stopPolling();
      BookingBadgeService.stopPolling();
    }
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
    if (_signedIn != true) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
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
