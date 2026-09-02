import 'package:flutter/material.dart';

/// Global theme and color settings for the GMS app.
class AppTheme {
  /// Main gradient (dark → light blue) used across the app
  static const LinearGradient gmsGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color(0xFF1565C0), // Dark blue
      Color(0xFF42A5F5), // Light blue
    ],
  );

  /// Primary GMS blue color (use this for buttons or highlights)
  static const Color primaryBlue = Color(0xFF1565C0);

  /// Secondary light blue (used for soft highlights)
  static const Color secondaryBlue = Color(0xFF42A5F5);

  /// The global light theme setup
  static final ThemeData lightTheme = ThemeData(
    useMaterial3: true,
    primaryColor: primaryBlue,
    scaffoldBackgroundColor: Colors.white,

    /// Default AppBar theme
    appBarTheme: const AppBarTheme(
      backgroundColor: primaryBlue,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: true,
      // Explicit color here matters — without it, this can fall back
      // to textTheme.titleLarge's black (set below) instead of
      // correctly inheriting foregroundColor, which is exactly what
      // caused every screen using the plain default AppBar (Edit
      // Profile, route screens, chat headers, and more) to show
      // black title text on the blue background instead of white.
      titleTextStyle: TextStyle(
          fontWeight: FontWeight.bold, fontSize: 20, color: Colors.white),
      iconTheme: IconThemeData(color: Colors.white),
    ),

    /// Text theme customization
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: Colors.black87, fontSize: 16),
      bodyMedium: TextStyle(color: Colors.black87),
      titleLarge: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
    ),

    /// BottomNavigationBar defaults
    bottomNavigationBarTheme: const BottomNavigationBarThemeData(
      backgroundColor: primaryBlue,
      selectedItemColor: Colors.white,
      unselectedItemColor: Colors.white70,
      type: BottomNavigationBarType.fixed,
    ),

    /// Cards: soft rounded, subtle elevation everywhere
    cardTheme: CardThemeData(
      elevation: 1,
      shadowColor: Colors.black12,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),

    /// Inputs: pill-rounded, filled, borderless
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: Color(0xFFE3F2FD)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: secondaryBlue, width: 1.5),
      ),
    ),

    /// Buttons: brand blue, rounded
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: primaryBlue,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      ),
    ),

    /// Snackbars floating, rounded
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
