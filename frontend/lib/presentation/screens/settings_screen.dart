import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:GMS/core/app_state.dart';
import 'package:GMS/presentation/screens/you_screen.dart' show EditProfileScreen;
import 'change_password_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  String get _selectedCurrency => AppState.selectedCurrency;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),

      // ✅ CUSTOM HEADER (FIXED)
      body: Column(
        children: [
          _customHeader(context),

          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _sectionTitle("Account"),

                _settingsTile(
                  icon: Icons.person_outline,
                  title: "Profile Settings",
                  onTap: () {
                    // Skip the You tab — go straight to Edit Profile.
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const EditProfileScreen(),
                      ),
                    );
                  },
                ),

                _settingsTile(
                  icon: Icons.lock_outline,
                  title: "Change Password",
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const ChangePasswordScreen(),
                      ),
                    );
                  },
                ),

                const SizedBox(height: 24),

                _sectionTitle("Preferences"),

                _settingsTile(
                  icon: Icons.language,
                  title: "Language",
                  subtitle: "English",
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'English is the only language available right now — more coming soon.')));
                  },
                ),

                _settingsTile(
                  icon: Icons.monetization_on_outlined,
                  title: "Currency",
                  subtitle: _selectedCurrency,
                  onTap: _openCurrencyPicker,
                ),

                _settingsTile(
                  icon: Icons.dark_mode_outlined,
                  title: "Theme",
                  subtitle: "Light",
                  onTap: () {
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text(
                            'Light theme is the only option right now — dark mode is coming soon.')));
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------- HEADER ----------------

  Widget _customHeader(BuildContext context) {
    return Container(
      height: 110,
      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 14),
      decoration: const BoxDecoration(
        color: Color(0xFF4A90E2),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(22)),
      ),
      child: SafeArea(
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            const SizedBox(width: 8),
            const Text(
              "Settings",
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- UI ----------------

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.bold,
          color: Colors.black54,
        ),
      ),
    );
  }

  Widget _settingsTile({
    required IconData icon,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ListTile(
        leading: Icon(icon, color: Colors.blue),
        title: Text(title),
        subtitle: subtitle != null
            ? Text(subtitle, style: const TextStyle(fontSize: 12))
            : null,
        trailing: const Icon(Icons.arrow_forward_ios, size: 16),
        onTap: onTap,
      ),
    );
  }

  // ---------------- CURRENCY ----------------

  void _openCurrencyPicker() async {
    final result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const CurrencyPicker(),
    );

    if (result != null) {
      setState(() {
        AppState.selectedCurrency = result;
      });
    }
  }
}

// ===================================================
// FAST CURRENCY PICKER (NO HEAVY API)
// ===================================================

class CurrencyPicker extends StatefulWidget {
  const CurrencyPicker({super.key});

  @override
  State<CurrencyPicker> createState() => _CurrencyPickerState();
}

class _CurrencyPickerState extends State<CurrencyPicker> {
  List<String> allCurrencies = [];
  List<String> filteredCurrencies = [];
  bool loading = true;
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadCurrencies();
    _searchController.addListener(_filterCurrencies);
  }

  Future<void> _loadCurrencies() async {
    final data = await rootBundle.loadString('assets/currencies.json');
    final List<dynamic> jsonList = json.decode(data);

    setState(() {
      allCurrencies = jsonList.cast<String>();
      filteredCurrencies = allCurrencies;
      loading = false;
    });
  }

  void _filterCurrencies() {
    final query = _searchController.text.toLowerCase();

    setState(() {
      filteredCurrencies = allCurrencies
          .where((c) => c.toLowerCase().contains(query))
          .toList();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.80,
      child: Column(
        children: [
          const SizedBox(height: 12),

          const Text(
            "Select Currency",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),

          const SizedBox(height: 10),

          // 🔍 SEARCH BAR
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: "Search currency...",
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),

          const SizedBox(height: 10),
          const Divider(),

          // 📜 LIST
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : filteredCurrencies.isEmpty
                ? const Center(child: Text("No currency found"))
                : ListView.builder(
                    itemCount: filteredCurrencies.length,
                    itemBuilder: (context, index) {
                      return ListTile(
                        title: Text(filteredCurrencies[index]),
                        onTap: () {
                          Navigator.pop(context, filteredCurrencies[index]);
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
