import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/config/company_info.dart';
import '../../core/api/app_meta_api.dart';

class AboutGmsScreen extends StatefulWidget {
  const AboutGmsScreen({super.key});

  @override
  State<AboutGmsScreen> createState() => _AboutGmsScreenState();
}

class _AboutGmsScreenState extends State<AboutGmsScreen> {
  String _version = '';
  static const int _foundingYear = 2025;
  // Falls back to the founding year alone if the server can't be
  // reached — never worse than what was shown before this feature
  // existed, and never trusts the device's own clock.
  int? _currentYear;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadCurrentYear();
  }

  Future<void> _loadCurrentYear() async {
    final year = await AppMetaApi.getCurrentYear();
    if (mounted && year != null) {
      setState(() => _currentYear = year);
    }
  }

  String get _copyrightYearText {
    final year = _currentYear;
    if (year == null || year <= _foundingYear) return '$_foundingYear';
    return '$_foundingYear–$year';
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() {
      _version = info.version; // 👈 ONLY 1.0.0 (no build number)
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        elevation: 0,
        centerTitle: true,
        title: const Text(
          "About GMS",
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
        children: [
          _branding(),

          const SizedBox(height: 25),
          _styledSection(
            icon: Icons.info_outline_rounded,
            title: "What is GMS?",
            content: const Text(
              "GMS (Get My Service) is a location-aware service marketplace connecting you with verified local professionals — electricians, plumbers, beauticians, home nurses, mechanics, tutors, and more — right in your neighborhood.\n\n"
              "Search by category or name, see who's genuinely nearby on a live map with real driving distance and time, book with two-step confirmation (provider accepts, then a simple advance secures it), and chat directly with your provider before, during, and after the job.\n\n"
              "Built for trust: real reviews, a full booking timeline you can check anytime, and secure cloud-backed accounts.",
              style: TextStyle(fontSize: 15, height: 1.55),
            ),
          ),

          const SizedBox(height: 20),
          _styledSection(
            icon: Icons.flag_circle_rounded,
            title: "Our Mission",
            content: const Text(
              "To offer fast, trusted, and high-quality services by connecting customers with the right professionals. "
              "We aim to deliver convenience, affordability, and transparency in every service experience.",
              style: TextStyle(fontSize: 15, height: 1.55),
            ),
          ),

          const SizedBox(height: 20),
          _styledSection(
            icon: Icons.workspace_premium_rounded,
            title: "Why Choose GMS?",
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                _Bullet("Verified & background-checked service professionals"),
                _Bullet(
                  "Flexible pricing: Hourly-based, Day-based, and Work/Project-based",
                ),
                _Bullet("Clear and transparent pricing with no hidden charges"),
                _Bullet("Instant booking with real-time chat support"),
                _Bullet("Secure payments via wallet, UPI, and cards"),
                _Bullet("Easy refunds & consumer-friendly cancellation"),
                _Bullet("Reliable job tracking and service history"),
                _Bullet("Wide range of services under one simple platform"),
              ],
            ),
          ),

          const SizedBox(height: 20),
          _styledSection(
            icon: Icons.remove_red_eye_rounded,
            title: "Our Vision",
            content: const Text(
              "To become India’s most reliable home-service platform by empowering skilled workers, "
              "adopting modern technology, and delivering convenience to every household.",
              style: TextStyle(fontSize: 15, height: 1.55),
            ),
          ),

          const SizedBox(height: 20),
          _styledSection(
            icon: Icons.contact_mail_rounded,
            title: "Contact Us",
            content: Text(
              "📧 ${CompanyInfo.supportEmail}\n"
              "📞 ${CompanyInfo.supportPhone}\n"
              "📍 ${CompanyInfo.address}",
              style: const TextStyle(fontSize: 15, height: 1.7),
            ),
          ),

          const SizedBox(height: 35),

          Center(
            child: Text(
              "Version $_version\n© $_copyrightYearText GMS - All Rights Reserved",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600, fontSize: 13),
            ),
          ),

          const SizedBox(height: 30),
        ],
      ),
    );
  }
}

// -----------------------------
// 🔹 Branding Section
// -----------------------------
Widget _branding() {
  return Column(
    children: [
      Image.asset("assets/images/gms_logo.png", height: 85),
      const SizedBox(height: 12),
      const Text(
        "GMS - Get My Service",
        style: TextStyle(fontSize: 23, fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 6),
      Text(
        "Your trusted partner for all home & personal services",
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.grey.shade700, fontSize: 14),
      ),
    ],
  );
}

// -----------------------------
// 🔹 Stylish Card Section
// -----------------------------
Widget _styledSection({
  required IconData icon,
  required String title,
  required Widget content,
}) {
  return Container(
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withOpacity(0.05),
          blurRadius: 10,
          offset: const Offset(1, 4),
        ),
      ],
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [Colors.blue.shade300, Colors.blue.shade700],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
              ),
              child: Icon(icon, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Text(
              title,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 12),
        content,
      ],
    ),
  );
}

// -----------------------------
// 🔹 Bullet List
// -----------------------------
class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 6),
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: Colors.blue.shade600,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 15, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
