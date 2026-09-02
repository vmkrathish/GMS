// lib/presentation/screens/you_screen.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';

import 'package:flutter_otp_text_field/flutter_otp_text_field.dart';

import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:http/http.dart' as http;

import 'package:GMS/core/widgets/gms_header.dart';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:path_provider/path_provider.dart';
import 'package:GMS/core/app_state.dart';
import 'package:GMS/core/currency/currencies_format.dart';

import 'package:GMS/core/api/service_api.dart';
import 'package:GMS/core/api/user_api.dart';
import 'package:GMS/core/services/api_service.dart' show ApiResult;
import 'package:GMS/core/api/geo_api.dart';
import 'package:GMS/core/config/api_config.dart';
import 'package:GMS/core/services/session_manager.dart';
import 'package:GMS/core/services/refresh_bus.dart';
import 'package:GMS/presentation/screens/auth/login_screen.dart';

/// 🔹 Service search — live from the GMS suggestion engine,
/// falls back to the built-in list if offline.
Future<List<String>> fetchServiceList(String query) async {
  final res = await ServiceApi.getSuggestions(query);
  if (res.success && res.data is Map && res.data['suggestions'] is List) {
    final live = List<String>.from(res.data['suggestions']);
    if (live.isNotEmpty) return live;
  }

  const allServices = [
    'Cleaning',
    'Plumbing',
    'Electrical Repair',
    'Welding',
    'Gardening',
    'House Cleaning',
    'Catering',
    'Home Nursing',
    'Physiotherapy',
    'Baby Sitting',
    'Elder Care',
    'Pest Control',
    'AC Repair',
    'Carpentry',
    'Painting',
    'Interior Work',
    'Water Purifier Service',
    'RO Service',
    'CCTV Installation & Repair',
    'Laptop Repair',
    'Mobile Repair',
    'Counseling',
    'Yoga Trainer',
    'Money Lending',
  ];

  return allServices
      .where((s) => s.toLowerCase().contains(query.toLowerCase()))
      .toList();
}

/// Global user data (for refresh after save)
final ValueNotifier<Map<String, dynamic>> userProfile = ValueNotifier({
  // Neutral loading placeholder — this used to be a real person's
  // actual name, email, and phone number, hardcoded here as the
  // starting value for EVERY session. That's what was showing up
  // for 5-6 seconds on every fresh sign-in/sign-up before the real
  // logged-in user's data replaced it — not a random glitch, but
  // someone else's real information appearing briefly on someone
  // else's screen. Never put real personal data in a shared default.
  'name': 'Loading…',
  'email': '',
  'phone': '',
  'dialCode': '+91',
  'location': '',
  'rating': '0.0',
  'bio': '',
  'avatar': null,          // local-only, ephemeral preview during upload
  'webImageBytes': null,   // local-only, ephemeral preview during upload
  'avatarUrl': null,       // server truth — the ONLY durable avatar source

  'country': 'India',
  'addressLine1': '',
  'areaStreetVillage': '',
  'landmark': '',
  'pincode': '',
  'city': '',
  'state': '',
  'latitude': null,
  'longitude': null,

  'primaryService': {
    'name': '',
    'charge': '',
    'type': 'fixed price',
  },
  'otherServices': <Map<String, String>>[],
});

// ═════════════════════════════════════════════
// SERVER SYNC LAYER
// Keeps the same ValueNotifier architecture — the UI code
// below is untouched; these helpers just fill/flush it
// against the GMS API + MySQL.
// ═════════════════════════════════════════════

String _unitToUi(String? dbUnit) => switch (dbUnit) {
      'per_hour' => 'per hour',
      'per_day' => 'per day',
      _ => 'fixed price', // covers 'fixed' and any unrecognized value —
      // previously this silently became 'per day', which is wrong for
      // one-time services (e.g. a website build billed as a flat fee).
    };
String _unitToDb(String? uiType) => switch (uiType) {
      'per hour' => 'per_hour',
      'per day' => 'per_day',
      _ => 'fixed',
    };

/// Pull profile + my services from the server into userProfile.
Future<void> loadProfileFromServer() async {
  final res = await UserApi.getMe();
  if (res.success && res.data is Map && res.data['user'] is Map) {
    final u = Map<String, dynamic>.from(res.data['user']);
    userProfile.value = {
      ...userProfile.value,
      'name': u['name'] ?? userProfile.value['name'],
      'email': u['email'] ?? '',
      'phone': u['phone'] ?? '',
      'dialCode': u['dial_code'] ?? '+91',
      'location': u['location_text'] ?? '',
      'bio': u['bio'] ?? '',
      'country': u['country'] ?? 'India',
      'addressLine1': u['address_line1'] ?? '',
      'areaStreetVillage': u['area_street_village'] ?? '',
      'landmark': u['landmark'] ?? '',
      'pincode': u['pincode'] ?? '',
      'city': u['city'] ?? '',
      'district': u['district'] ?? '',
      'state': (u['state'] ?? '').toString().toUpperCase(),
      'latitude': u['latitude'] == null
          ? null
          : double.tryParse('${u['latitude']}'),
      'longitude': u['longitude'] == null
          ? null
          : double.tryParse('${u['longitude']}'),
      // Server is the ONLY source of truth for the avatar. Every fresh
      // load clears any local-only preview left behind by a PREVIOUS
      // account in this browser session — this is what stops one
      // person's picked photo from "leaking" onto the next login.
      'avatarUrl': u['avatar_url'],
      'avatar': null,
      'webImageBytes': null,
    };
    SessionManager.saveUser(u);
  }

  // My services → primaryService + otherServices
  final me = await SessionManager.getUser();
  final myId = int.tryParse('${me?['id']}');
  if (myId != null) {
    final sres = await ServiceApi.getServices(providerId: myId);
    if (sres.success && sres.data is Map && sres.data['services'] is List) {
      final list = List<Map<String, dynamic>>.from(
          (sres.data['services'] as List).map((e) => Map<String, dynamic>.from(e)));
      if (list.isNotEmpty) {
        list.sort((a, b) =>
            ('${b['is_primary'] ?? 0}').compareTo('${a['is_primary'] ?? 0}'));
        final primary = list.first;
        final others = list.skip(1).toList();
        double avg = 0;
        int cnt = 0;
        for (final s in list) {
          final r = double.tryParse('${s['average_rating'] ?? 0}') ?? 0;
          if (r > 0) { avg += r; cnt++; }
        }
        userProfile.value = {
          ...userProfile.value,
          'rating': cnt > 0 ? (avg / cnt).toStringAsFixed(1) : userProfile.value['rating'],
          'primaryService': {
            'name': primary['title'] ?? '',
            'charge': '${primary['price'] ?? ''}'.replaceAll(RegExp(r'\.00$'), ''),
            'type': _unitToUi('${primary['price_unit']}'),
            'id': primary['id'],
          },
          'otherServices': [
            for (final o in others)
              {
                'name': '${o['title'] ?? ''}',
                'charge': '${o['price'] ?? ''}'.replaceAll(RegExp(r'\.00$'), ''),
                'type': _unitToUi('${o['price_unit']}'),
                'id': o['id'],
              }
          ],
        };
      }
    }
  }
  userProfile.notifyListeners();
}

/// Push profile fields (identity + full address + coordinates).
/// Returns the full result (not just success/fail) so the caller can
/// tell a genuine network problem apart from the server explicitly
/// rejecting a value (e.g. a duplicate phone number) — those need
/// very different messages and different follow-up behavior.
Future<ApiResult> saveProfileToServer() async {
  final p = userProfile.value;
  final res = await UserApi.updateProfile({
    'name': p['name'],
    'email': p['email'],
    'phone': p['phone'],
    'dial_code': p['dialCode'],
    'location_text': p['location'],
    'country': p['country'],
    'address_line1': p['addressLine1'],
    'area_street_village': p['areaStreetVillage'],
    'landmark': p['landmark'],
    'pincode': p['pincode'],
    'city': p['city'],
    'district': p['district'],
    'state': p['state'],
    if (p['latitude'] != null) 'latitude': p['latitude'],
    if (p['longitude'] != null) 'longitude': p['longitude'],
  });
  return res;
}

/// Push primary + other services (upsert by id, create new ones).
/// Returns a list of human-readable error messages for anything
/// that failed to save — empty list means everything succeeded.
/// Previously this returned nothing and callers never checked
/// success/failure at all, so a save the backend correctly rejected
/// (e.g. a price outside the platform-controlled allowed range)
/// failed completely silently — the dialog closed as if it worked,
/// and the person had no idea their change never actually saved.
Future<List<String>> syncServicesToServer() async {
  final p = userProfile.value;
  final primary = Map<String, dynamic>.from(p['primaryService'] ?? {});
  final others = List<Map<String, dynamic>>.from(
      (p['otherServices'] as List? ?? []).map((e) => Map<String, dynamic>.from(e as Map)));
  final errors = <String>[];

  Future<void> upsert(Map<String, dynamic> svc, bool isPrimary) async {
    final name = (svc['name'] ?? '').toString().trim();
    if (name.isEmpty) return;
    final body = {
      'title': name,
      'price': (svc['charge'] ?? '0').toString(),
      'price_unit': _unitToDb(svc['type']?.toString()),
      'is_primary': isPrimary ? 1 : 0,
      'city': (p['city'] ?? '').toString(),
      'category_id': 41, // 'General Services' bucket; user can refine later
    };
    final id = svc['id'];
    final res = id != null
        ? await ServiceApi.updateService(int.parse('$id'), body)
        : await ServiceApi.createService(body);
    if (!res.success) {
      final reason = res.message.isNotEmpty ? res.message : 'could not be saved';
      errors.add('$name: $reason');
    }
  }

  await upsert(primary, true);
  for (final o in others) {
    await upsert(o, false);
  }
  return errors;
}

String getCurrencySymbol() {
  final full = AppState.selectedCurrency;
  if (full.isEmpty) return '₹';
  return full.split(' ').first.trim();
}

class ServiceSearchField extends StatefulWidget {
  final String hint;
  final ValueChanged<String> onSelected;
  final TextEditingController? controller;

  const ServiceSearchField({
    super.key,
    required this.hint,
    required this.onSelected,
    this.controller,
  });

  @override
  State<ServiceSearchField> createState() => _ServiceSearchFieldState();
}

class _ServiceSearchFieldState extends State<ServiceSearchField> {
  late TextEditingController _controller;
  bool _ownsController = false;

  // separate focus nodes
  final FocusNode _textFieldNode = FocusNode();
  final FocusNode _keyboardNode = FocusNode();

  List<String> _results = [];
  int _highlightIndex = -1;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? TextEditingController();
    _ownsController = widget.controller == null;
    // initialize controller text if provided by widget
    if (widget.controller != null) {
      _controller.text = widget.controller!.text;
    }
  }

  Future<void> _search(String q) async {
    if (q.trim().isEmpty) {
      setState(() {
        _results.clear();
        _highlightIndex = -1;
      });
      return;
    }

    setState(() => _loading = true);

    final res = await fetchServiceList(q);

    if (!mounted) return;

    setState(() {
      _results = res;
      _highlightIndex = res.isNotEmpty ? 0 : -1;
      _loading = false;
    });
  }

  void _selectItem(int index) {
    final value = _results[index];
    widget.onSelected(value);
    _controller.text = value;
    _results.clear();
    _highlightIndex = -1;
    FocusScope.of(context).unfocus();
    setState(() {});
  }

  void _handleKey(RawKeyEvent event) {
    if (_results.isEmpty || event is! RawKeyDownEvent) return;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightIndex = (_highlightIndex + 1) % _results.length;
      });
    } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightIndex =
            (_highlightIndex - 1 + _results.length) % _results.length;
      });
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      if (_highlightIndex >= 0) {
        _selectItem(_highlightIndex);
      }
    } else if (event.logicalKey == LogicalKeyboardKey.escape) {
      setState(() {
        _results.clear();
        _highlightIndex = -1;
      });
    }
  }

  @override
  void dispose() {
    _textFieldNode.dispose();
    _keyboardNode.dispose();
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawKeyboardListener(
      focusNode: _keyboardNode, // ✅ different node
      onKey: _handleKey,
      child: Column(
        children: [
          TextField(
            controller: _controller,
            focusNode: _textFieldNode, // ✅ separate node
            onChanged: _search,
            decoration: InputDecoration(
              hintText: widget.hint,
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _loading
                  ? const Padding(
                      padding: EdgeInsets.all(10),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
          ),

          if (_results.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 6),
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: ListView.builder(
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final selected = i == _highlightIndex;
                  return InkWell(
                    onTap: () => _selectItem(i),
                    child: Container(
                      color: selected
                          ? Colors.blue.shade50
                          : Colors.transparent,
                      padding: const EdgeInsets.symmetric(
                        vertical: 10,
                        horizontal: 12,
                      ),
                      child: Text(
                        _results[i],
                        style: TextStyle(
                          fontWeight: selected
                              ? FontWeight.w600
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

/// Show full-screen avatar viewer with Edit / Remove actions.
Future<void> showAvatarViewer(BuildContext context, Map profile) async {
  final Map<String, dynamic> safeProfile = Map<String, dynamic>.from(profile);
  final avatarUrl = ApiConfig.resolveMediaUrl(safeProfile['avatarUrl']?.toString());
  final hasWebBytes = safeProfile['webImageBytes'] != null;
  final avatarPath = safeProfile['avatar'] as String?;
  final hasNetwork = avatarUrl != null;
  if (!hasNetwork &&
      !hasWebBytes &&
      (avatarPath == null || avatarPath.isEmpty)) return;

  ImageProvider provider;
  if (hasWebBytes) {
    provider = MemoryImage(safeProfile['webImageBytes'] as Uint8List);
  } else if (avatarPath != null && avatarPath.isNotEmpty) {
    provider = FileImage(File(avatarPath));
  } else {
    provider = NetworkImage(avatarUrl!);
  }

  await showDialog(
    context: context,
    builder: (ctx) {
      return Dialog(
        insetPadding: EdgeInsets.zero,
        backgroundColor: Colors.black.withOpacity(0.9),
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(child: Image(image: provider)),
            ),

            // CLOSE BUTTON
            Positioned(
              top: 20,
              left: 20,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white, size: 30),
                onPressed: () => Navigator.of(ctx).pop(),
              ),
            ),

            // ACTIONS: Edit (open EditProfileScreen) and Remove
            Positioned(
              top: 20,
              right: 20,
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Edit photo',
                    icon: const Icon(Icons.edit, color: Colors.white),
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => const EditProfileScreen(),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    tooltip: 'Remove photo',
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Colors.redAccent,
                    ),
                    onPressed: () async {
                      Navigator.of(ctx).pop();
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (c2) => AlertDialog(
                          title: const Text('Remove avatar'),
                          content: const Text(
                            'Do you want to remove your profile photo?',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(c2).pop(false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(c2).pop(true),
                              child: const Text(
                                'Remove',
                                style: TextStyle(color: Colors.red),
                              ),
                            ),
                          ],
                        ),
                      );

                      if (confirmed != true) return;

                      // remove local file if exists
                      try {
                        final path = userProfile.value['avatar'] as String?;
                        if (path != null && path.isNotEmpty) {
                          final f = File(path);
                          if (f.existsSync()) await f.delete();
                        }
                      } catch (_) {}

                      // Remove server-side — this is what every other
                      // screen (Home, Chat, Bookings) actually reads.
                      // The result is CHECKED — a previous version
                      // ignored it and showed "removed" even when the
                      // server call had actually failed, so the photo
                      // reappeared after any restart.
                      final delRes = await UserApi.deleteAvatar();

                      if (!context.mounted) return;

                      if (delRes.success) {
                        userProfile.value = {
                          ...userProfile.value,
                          'avatar': null,
                          'webImageBytes': null,
                          'avatarUrl': null,
                        };
                        userProfile.notifyListeners();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Profile photo removed ✅'),
                          ),
                        );
                      } else {
                        // Do NOT touch local/avatarUrl state — leave the
                        // photo exactly as it was so the UI never lies
                        // about what's actually saved on the server.
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            backgroundColor: Colors.red.shade700,
                            duration: const Duration(seconds: 6),
                            content: Text(delRes.isOffline
                                ? 'Photo NOT removed — unable to connect. Please try again.'
                                : 'Photo NOT removed — ${delRes.message}'),
                          ),
                        );
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

class YouScreen extends StatefulWidget {
  const YouScreen({super.key});

  @override
  State<YouScreen> createState() => _YouScreenState();
}

class _YouScreenState extends State<YouScreen> {
  @override
  void initState() {
    super.initState();
    loadProfileFromServer(); // fill the notifier from MySQL
    RefreshBus.profile.addListener(_onRefreshBusProfile);
  }

  void _onRefreshBusProfile() {
    if (!mounted) return;
    loadProfileFromServer();
  }

  @override
  void dispose() {
    RefreshBus.profile.removeListener(_onRefreshBusProfile);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, dynamic>>(
      valueListenable: userProfile,
      builder: (context, profile, _) {
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GMSHeader(parentContext: context),
            const SizedBox(height: 16),
            _profileCard(context, profile),
            const SizedBox(height: 16),
            _settingsCard(context),
          ],
        );
      },
    );
  }

  void showEditServiceDialog(BuildContext context) {
    final Map<String, dynamic> primary = Map<String, dynamic>.from(
      userProfile.value['primaryService'] ?? {},
    );

    final TextEditingController primaryNameCtrl = TextEditingController(
      text: primary['name']?.toString() ?? '',
    );

    final TextEditingController primaryChargeCtrl = TextEditingController(
      text: primary['charge']?.toString() ?? '',
    );

    String primaryType = primary['type']?.toString() ?? 'fixed price';

    /// Each other service row holds its own controllers
    final List<Map<String, dynamic>> otherServices =
        (userProfile.value['otherServices'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .map(
              (e) => {
                'nameCtrl': TextEditingController(text: e['name'] ?? ''),
                'chargeCtrl': TextEditingController(text: e['charge'] ?? ''),
                'type': e['type'] ?? '',
              },
            )
            .toList() ??
        [];

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text("Edit Service"),

          // Height is relative to the actual screen, not a small
          // fixed number — 440px wasn't enough once a provider had
          // 6+ "Other Services" rows, causing a real overflow (the
          // SingleChildScrollView below can only help once the
          // dialog itself has enough room to begin with).
          content: SizedBox(
            width: 420,
            height: MediaQuery.of(context).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ───────── PRIMARY SERVICE ─────────
                  const Text(
                    "Primary Service",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  ServiceSearchField(
                    hint: "Search service",
                    controller: primaryNameCtrl,
                    onSelected: (v) => primaryNameCtrl.text = v,
                  ),
                  const SizedBox(height: 10),

                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: primaryChargeCtrl,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: "Charge (${AppState.selectedCurrency})",
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: primaryType,
                          decoration: const InputDecoration(
                            labelText: "Type",
                            border: OutlineInputBorder(),
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: "fixed price",
                              child: Text("Fixed Price"),
                            ),
                            DropdownMenuItem(
                              value: "per day",
                              child: Text("Per Day"),
                            ),
                            DropdownMenuItem(
                              value: "per hour",
                              child: Text("Per Hour"),
                            ),
                          ],
                          onChanged: (v) => primaryType = v ?? 'fixed price',
                        ),
                      ),
                    ],
                  ),

                  const Divider(height: 30),

                  // ───────── OTHER SERVICES ─────────
                  const Text(
                    "Other Services",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  ...List.generate(otherServices.length, (i) {
                    final row = otherServices[i];

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final isMobile = constraints.maxWidth < 520;

                          // 📱 MOBILE → STACKED
                          if (isMobile) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                ServiceSearchField(
                                  hint: "Service",
                                  controller: row['nameCtrl'],
                                  onSelected: (v) => row['nameCtrl'].text = v,
                                ),
                                const SizedBox(height: 8),

                                TextField(
                                  controller: row['chargeCtrl'],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    labelText:
                                        "Charge (${AppState.selectedCurrency})",
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                                const SizedBox(height: 8),

                                Row(
                                  children: [
                                    Expanded(
                                      child: DropdownButtonFormField<String>(
                                        value: row['type'].isEmpty
                                            ? null
                                            : row['type'],
                                        decoration: const InputDecoration(
                                          labelText: "Type",
                                          border: OutlineInputBorder(),
                                        ),
                                        items: const [
                                          DropdownMenuItem(
                                            value: "fixed price",
                                            child: Text("Fixed Price"),
                                          ),
                                          DropdownMenuItem(
                                            value: "per day",
                                            child: Text("Per Day"),
                                          ),
                                          DropdownMenuItem(
                                            value: "per hour",
                                            child: Text("Per Hour"),
                                          ),
                                        ],
                                        onChanged: (v) {
                                          row['type'] = v ?? '';
                                          (context as Element).markNeedsBuild();
                                        },
                                      ),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.close,
                                        color: Colors.red,
                                      ),
                                      onPressed: () {
                                        otherServices.removeAt(i);
                                        (context as Element).markNeedsBuild();
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            );
                          }

                          // 💻 DESKTOP / TABLET → HORIZONTAL
                          return Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: ServiceSearchField(
                                  hint: "Service",
                                  controller: row['nameCtrl'],
                                  onSelected: (v) => row['nameCtrl'].text = v,
                                ),
                              ),
                              const SizedBox(width: 8),

                              Expanded(
                                flex: 2,
                                child: TextField(
                                  controller: row['chargeCtrl'],
                                  keyboardType: TextInputType.number,
                                  decoration: InputDecoration(
                                    hintText: "(${AppState.selectedCurrency})",
                                    border: const OutlineInputBorder(),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),

                              Expanded(
                                flex: 2,
                                child: DropdownButtonFormField<String>(
                                  value: row['type'].isEmpty
                                      ? null
                                      : row['type'],
                                  decoration: const InputDecoration(
                                    labelText: "Type",
                                    border: OutlineInputBorder(),
                                  ),
                                  items: const [
                                    DropdownMenuItem(
                                      value: "fixed price",
                                      child: Text("Fixed Price"),
                                    ),
                                    DropdownMenuItem(
                                      value: "per day",
                                      child: Text("Per Day"),
                                    ),
                                    DropdownMenuItem(
                                      value: "per hour",
                                      child: Text("Per Hour"),
                                    ),
                                  ],
                                  onChanged: (v) {
                                    row['type'] = v ?? '';
                                    (context as Element).markNeedsBuild();
                                  },
                                ),
                              ),

                              IconButton(
                                icon: const Icon(
                                  Icons.close,
                                  color: Colors.red,
                                ),
                                onPressed: () {
                                  otherServices.removeAt(i);
                                  (context as Element).markNeedsBuild();
                                },
                              ),
                            ],
                          );
                        },
                      ),
                    );
                  }),

                  TextButton.icon(
                    onPressed: () {
                      otherServices.add({
                        'nameCtrl': TextEditingController(),
                        'chargeCtrl': TextEditingController(),
                        'type': '',
                      });
                      (ctx as Element).markNeedsBuild();
                    },
                    icon: const Icon(Icons.add),
                    label: const Text("Add Service"),
                  ),
                ],
              ),
            ),
          ),

          // ───────── ACTIONS ─────────
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),
            ElevatedButton(
              onPressed: () {
                // ✅ PRIMARY VALIDATION
                if (primaryNameCtrl.text.trim().isEmpty ||
                    primaryChargeCtrl.text.trim().isEmpty ||
                    primaryType.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text("⚠️ Fill all primary service details"),
                      duration: Duration(seconds: 4),
                    ),
                  );
                  return;
                }

                // ✅ CLEAN & VALIDATE OTHER SERVICES
                final List<Map<String, String>> cleanedOther = [];

                for (final row in otherServices) {
                  final name = row['nameCtrl'].text.trim();
                  final charge = row['chargeCtrl'].text.trim();
                  final type = row['type'].toString().trim();

                  // skip fully empty rows
                  if (name.isEmpty && charge.isEmpty && type.isEmpty) {
                    continue;
                  }

                  // block partial rows
                  if (name.isEmpty || charge.isEmpty || type.isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          "⚠️ Fill all fields in Other Services or remove the row",
                        ),
                        duration: Duration(seconds: 4),
                      ),
                    );
                    return;
                  }

                  cleanedOther.add({
                    'name': name,
                    'charge': charge,
                    'type': type,
                  });
                }

                // A service's city comes from the shared profile
                // address, not a field in this dialog — a brand-new
                // signup who hasn't set their city yet would
                // otherwise hit a confusing backend rejection here
                // ("title, category_id and city are required" even
                // though title is clearly filled in). Catch it here
                // instead, with a message that actually tells them
                // what to do.
                if ((userProfile.value['city'] ?? '').toString().trim().isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    duration: Duration(seconds: 5),
                    content: Text(
                        'Please set your city in Edit Profile before adding a service.'),
                  ));
                  return;
                }

                // ✅ SAVE
                userProfile.value = Map<String, dynamic>.from({
                  ...userProfile.value,
                  'primaryService': {
                    'name': primaryNameCtrl.text.trim(),
                    'charge': primaryChargeCtrl.text.trim(),
                    'type': primaryType,
                  },
                  'otherServices': cleanedOther,
                });

                userProfile.notifyListeners();
                Navigator.pop(ctx);

                // Push services to the server, then reload (gets
                // IDs/ratings) — and actually show the person if
                // anything failed, instead of silently discarding
                // it. A price the platform's pricing rules reject
                // (see PUT /services/{id}'s validation) is the most
                // likely real-world case this surfaces.
                syncServicesToServer().then((errors) {
                  loadProfileFromServer();
                  if (errors.isNotEmpty && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      duration: const Duration(seconds: 6),
                      content: Text(
                          'Some changes were not saved:\n${errors.join('\n')}'),
                    ));
                  }
                });
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  void showViewServiceDialog(BuildContext context) {
    final primary = userProfile.value['primaryService'];
    final others = userProfile.value['otherServices'] as List;

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          title: const Text("Service Details"),
          content: SizedBox(
            width: 420,
            // No height limit + no scroll wrapper here at all before
            // this fix — that's why this specific dialog (distinct
            // from the "Edit Service" one) overflowed with zero way
            // to scroll once a provider had 6+ services. Adaptive
            // height + a real scroll view, same fix pattern as the
            // edit dialog.
            height: MediaQuery.of(context).size.height * 0.7,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // PRIMARY
                const Text(
                  "Primary Service",
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 10),

                _serviceRow(
                  primary['name'],
                  primary['charge'],
                  primary['type'],
                ),

                if (others.isNotEmpty) ...[
                  const SizedBox(height: 20),
                  const Text(
                    "Other Services",
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),

                  ...others.map(
                    (s) => _serviceRow(s['name'], s['charge'], s['type']),
                  ),
                ],
              ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }

  Widget _serviceRow(String name, String charge, String type) {
    final symbol = getCurrencySymbol();

    return Container(
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        children: [
          // Service name
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  type,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ],
            ),
          ),

          // Price badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              CurrencyFormatter.format(charge),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileCard(BuildContext context, Map<String, dynamic> profile) {
    ImageProvider? avatarProvider;
    final avatarUrl = ApiConfig.resolveMediaUrl(profile['avatarUrl']?.toString());
    if (kIsWeb) {
      final Uint8List? bytes = profile['webImageBytes'];
      if (bytes != null) {
        avatarProvider = MemoryImage(bytes); // just picked — instant preview
      } else if (avatarUrl != null) {
        avatarProvider = NetworkImage(avatarUrl); // server truth
      }
    } else {
      final String? path = profile['avatar'];
      if (path != null && File(path).existsSync()) {
        avatarProvider = FileImage(File(path)); // just picked — instant preview
      } else if (avatarUrl != null) {
        avatarProvider = NetworkImage(avatarUrl); // server truth
      }
    }

    final initials = (profile['name'] as String)
        .split(' ')
        .where((e) => e.isNotEmpty)
        .map((e) => e[0])
        .take(2)
        .join();

    final fullAddress = [
      (profile['addressLine1'] ?? '').toString().trim(),
      (profile['areaStreetVillage'] ?? '').toString().trim(),
      (profile['landmark'] ?? '').toString().trim(),
      (profile['city'] ?? '').toString().trim(),
      (profile['state'] ?? '').toString().trim(),
      (profile['pincode'] ?? '').toString().trim(),
      (profile['country'] ?? '').toString().trim(),
    ].where((p) => p.isNotEmpty).join(', ');

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            // Use Builder to ensure a local BuildContext if needed for dialogs.
            Builder(
              builder: (ctx) {
                return GestureDetector(
                  onTap: avatarProvider == null
                      ? null
                      : () => showAvatarViewer(ctx, profile),
                  child: CircleAvatar(
                    radius: 45,
                    backgroundColor: Colors.blue[100],
                    backgroundImage: avatarProvider,
                    child: avatarProvider == null
                        ? Text(
                            initials,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w600,
                              color: Colors.indigo,
                            ),
                          )
                        : null,
                  ),
                );
              },
            ),
            const SizedBox(height: 10),
            Text(
              profile['name'],
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),

            const SizedBox(height: 4),

            Text(
              profile['primaryService']['name'].toString().isEmpty
                  ? "Service not set"
                  : profile['primaryService']['name'],
              style: const TextStyle(
                fontSize: 14,
                color: Colors.blueGrey,
                fontWeight: FontWeight.w500,
              ),
            ),

            const SizedBox(height: 6),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => showViewServiceDialog(context),
                  icon: const Icon(Icons.visibility, size: 18),
                  label: const Text("View"),
                ),
                const SizedBox(width: 12),
                TextButton.icon(
                  onPressed: () => showEditServiceDialog(context),
                  icon: const Icon(Icons.edit, size: 18),
                  label: const Text("Edit"),
                ),
              ],
            ),

            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.star, color: Colors.amber),
                Text('${profile['rating']} Rating'),
              ],
            ),
            const Divider(height: 25),
            ListTile(
              leading: const Icon(Icons.phone),
              title: Text("${profile['dialCode']} ${profile['phone']}"),
            ),
            ListTile(
              leading: const Icon(Icons.email_outlined),
              title: Text(profile['email']),
            ),
            ListTile(
              leading: const Icon(Icons.location_on_outlined),
              title: Text(profile['location']),
            ),

            // Compact full address (single line / wraps to 2 lines max)
            if (fullAddress.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.home_outlined),
                title: Text(
                  fullAddress,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),

            const SizedBox(height: 6),
            _bioSection(context, (profile['bio'] ?? '').toString()),
          ],
        ),
      ),
    );
  }

  Widget _bioSection(BuildContext context, String bio) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.indigo.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.indigo.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: const [
                  Icon(Icons.info_outline, size: 18, color: Colors.indigo),
                  SizedBox(width: 6),
                  Text('About',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: Colors.indigo)),
                ],
              ),
              TextButton.icon(
                onPressed: () => _showEditBioDialog(context, bio),
                icon: Icon(bio.isEmpty ? Icons.add : Icons.edit,
                    size: 16),
                label: Text(bio.isEmpty ? 'Add bio' : 'Edit'),
                style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact),
              ),
            ],
          ),
          if (bio.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              bio,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),
          ] else ...[
            const SizedBox(height: 4),
            const Text(
              'Tell customers what you do — your work, specialties, and anything that makes your service stand out.',
              style: TextStyle(
                  fontSize: 12.5, color: Colors.black45, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  void _showEditBioDialog(BuildContext context, String currentBio) {
    final ctrl = TextEditingController(text: currentBio);
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('About you'),
          content: SizedBox(
            width: 420,
            child: TextField(
              controller: ctrl,
              maxLength: 500,
              maxLines: 6,
              minLines: 4,
              // maxLength on its own gives the live "245/500" counter
              // underneath, for free — no separate counter widget needed.
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText:
                    'Describe your work, specialties, and what makes your service stand out...',
              ),
              onChanged: (_) => setD(() {}),
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final text = ctrl.text.trim();
                Navigator.pop(ctx);
                final res =
                    await UserApi.updateProfile({'bio': text});
                if (!context.mounted) return;
                if (res.success) {
                  userProfile.value = {
                    ...userProfile.value,
                    'bio': text,
                  };
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Bio updated')));
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(res.message.isNotEmpty
                          ? res.message
                          : 'Could not update bio')));
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showServiceEditDialog(BuildContext context) {
    final TextEditingController serviceCtrl = TextEditingController(
      text: userProfile.value['service'] ?? '',
    );

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          title: const Text("Edit Service"),

          content: TextField(
            controller: serviceCtrl,
            decoration: const InputDecoration(
              labelText: "Enter service name",
              border: OutlineInputBorder(),
            ),
          ),

          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text("Cancel"),
            ),

            ElevatedButton(
              onPressed: () {
                userProfile.value = {
                  ...userProfile.value,
                  'service': serviceCtrl.text.trim(),
                };
                userProfile.notifyListeners();
                Navigator.pop(ctx);
              },
              child: const Text("Save"),
            ),
          ],
        );
      },
    );
  }

  Widget _settingsCard(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          // Keep only Edit Profile
          ListTile(
            leading: const Icon(Icons.edit),
            title: const Text('Edit Profile'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const EditProfileScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),

          // Logout (you can keep/remove if you want)
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text(
              'Logout',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
            onTap: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16)),
                  title: const Text('Logout?'),
                  content: const Text(
                      'You will need to sign in again to use GMS.'),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Logout',
                            style: TextStyle(color: Colors.red))),
                  ],
                ),
              );
              if (confirm != true || !context.mounted) return;
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
    );
  }
}

// ✏️ Edit Profile Screen
class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  Timer? _otpTimer;
  int _otpSeconds = 30;
  bool _canResendOtp = false;
  File? _imageFile;
  final ImagePicker _picker = ImagePicker();

  // Core profile controllers
  late TextEditingController _nameController;
  late TextEditingController _emailController;
  late TextEditingController _phoneController;
  late TextEditingController _locationController;

  final CropController _cropController = CropController();

  /// Show a simple full-screen view of the current avatar (dismiss on tap).
  Future<void> _viewAvatar() async {
    final avatarUrl = ApiConfig.resolveMediaUrl(userProfile.value['avatarUrl']?.toString());
    final hasNetwork = avatarUrl != null;
    final hasWebBytes = userProfile.value['webImageBytes'] != null;
    final avatarPath = userProfile.value['avatar'] as String?;

    // If nothing to view, bail out
    if (!hasNetwork &&
        !hasWebBytes &&
        (avatarPath == null || avatarPath.isEmpty)) return;

    await showDialog(
      context: context,
      builder: (ctx) {
        ImageProvider provider;
        if (hasWebBytes) {
          provider = MemoryImage(userProfile.value['webImageBytes']);
        } else if (avatarPath != null && avatarPath.isNotEmpty) {
          provider = FileImage(File(avatarPath));
        } else {
          provider = NetworkImage(avatarUrl!);
        }

        return GestureDetector(
          onTap: () => Navigator.of(ctx).pop(),
          child: Dismissible(
            key: const ValueKey('avatarViewer'),
            direction: DismissDirection.vertical,
            onDismissed: (_) => Navigator.of(ctx).pop(),
            child: Dialog(
              insetPadding: EdgeInsets.zero,
              backgroundColor: Colors.black.withOpacity(0.9),
              child: Stack(
                children: [
                  Center(
                    child: InteractiveViewer(child: Image(image: provider)),
                  ),
                  Positioned(
                    top: 18,
                    left: 14,
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ),
                  Positioned(
                    top: 18,
                    right: 14,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit, color: Colors.white),
                          onPressed: () {
                            Navigator.of(ctx).pop();
                            _chooseImageSource();
                          },
                        ),
                        IconButton(
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                          onPressed: () async {
                            Navigator.of(ctx).pop();
                            await _removeAvatar();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _viewAvatarFromHome(BuildContext context, Map<String, dynamic> profile) {
    final avatarUrl = ApiConfig.resolveMediaUrl(profile['avatarUrl']?.toString());
    final hasNetwork = avatarUrl != null;
    final hasWebBytes = profile['webImageBytes'] != null;
    final avatarPath = profile['avatar'] as String?;

    if (!hasNetwork &&
        !hasWebBytes &&
        (avatarPath == null || avatarPath.isEmpty)) return;

    ImageProvider provider;

    if (hasWebBytes) {
      provider = MemoryImage(profile['webImageBytes']);
    } else if (avatarPath != null && avatarPath.isNotEmpty) {
      provider = FileImage(File(avatarPath));
    } else {
      provider = NetworkImage(avatarUrl!);
    }

    showDialog(
      context: context,
      builder: (ctx) {
        return Dialog(
          insetPadding: EdgeInsets.zero,
          backgroundColor: Colors.black.withOpacity(0.9),
          child: Stack(
            children: [
              Center(
                child: InteractiveViewer(child: Image(image: provider)),
              ),

              // CLOSE BUTTON
              Positioned(
                top: 20,
                left: 20,
                child: IconButton(
                  icon: const Icon(Icons.close, color: Colors.white, size: 30),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Remove avatar from profile (confirms first)
  Future<void> _removeAvatar() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: const Text('Remove avatar'),
        content: const Text('Do you want to remove your profile photo?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dctx).pop(true),
            child: const Text('Remove', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    // remove persisted local file if any (best-effort)
    try {
      final avatarPath = userProfile.value['avatar'] as String?;
      if (avatarPath != null && avatarPath.isNotEmpty) {
        final f = File(avatarPath);
        if (f.existsSync()) await f.delete();
      }
    } catch (_) {}

    // Remove server-side — this was previously MISSING entirely from
    // this specific method, which is why the photo always came back
    // after restarting the app: it was never actually deleted from
    // the database, only hidden from the current in-memory state.
    final delRes = await UserApi.deleteAvatar();

    if (!mounted) return;

    if (delRes.success) {
      setState(() {
        _imageFile = null;
        userProfile.value = {
          ...userProfile.value,
          'avatar': null,
          'webImageBytes': null,
          'avatarUrl': null, // must clear this too, or the old photo
                              // just falls back into view immediately
        };
      });
      userProfile.notifyListeners();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo removed ✅')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: Colors.red.shade700,
          duration: const Duration(seconds: 6),
          content: Text(delRes.isOffline
              ? 'Photo NOT removed — unable to connect. Please try again.'
              : 'Photo NOT removed — ${delRes.message}'),
        ),
      );
    }
  }

  /// Save cropped bytes into app documents (avatars folder), update state & profile.
  /// The single place that actually persists a new avatar to the
  /// server. Called after every crop (camera or gallery, web or
  /// native) so avatar_url — the field every OTHER screen in the
  /// app reads — is always kept in sync. Local bytes/file are kept
  /// only as an instant preview; once this call succeeds they're
  /// cleared in favor of the real server URL.
  Future<void> _uploadAndSyncAvatar(Uint8List cropped) async {
    final res = await UserApi.uploadAvatar(cropped, 'avatar.png');
    if (!mounted) return;
    if (res.success && res.data is Map && res.data['user'] is Map) {
      final u = Map<String, dynamic>.from(res.data['user']);
      setState(() {
        userProfile.value = {
          ...userProfile.value,
          'avatarUrl': u['avatar_url'],
          'avatar': null,
          'webImageBytes': null,
        };
      });
      userProfile.notifyListeners();
      await SessionManager.saveUser(u);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Profile photo updated ✅')));
      }
    } else {
      // Deliberately loud & long-lived — a silent upload failure is
      // exactly what caused the earlier "photo not showing" bug, so
      // this must never go unnoticed again.
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 6),
        content: Text(res.isOffline
            ? 'Photo NOT saved — unable to connect. Please try again.'
            : 'Photo NOT saved — ${res.message}'),
      ));
    }
  }

  Future<void> _saveCroppedBytesToPersistentFile(Uint8List cropped) async {
    try {
      // Get a persistent app directory (documents)
      final dir = await getApplicationDocumentsDirectory();
      final avatarsDir = Directory('${dir.path}/avatars');
      if (!avatarsDir.existsSync()) {
        avatarsDir.createSync(recursive: true);
      }

      final filename = 'avatar_${DateTime.now().millisecondsSinceEpoch}.png';
      final file = File('${avatarsDir.path}/$filename');

      await file.writeAsBytes(cropped, flush: true);

      // Update local preview & global profile immediately
      if (!mounted) return;
      setState(() {
        _imageFile = file;
        userProfile.value = {
          ...userProfile.value,
          'avatar': file.path,
          // keep any webImageBytes if present
          'webImageBytes': userProfile.value['webImageBytes'],
        };
      });
      userProfile.notifyListeners();

      // optional feedback
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Avatar updated')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save cropped image')),
        );
      }
    }
  }

  /// Helper: show a crop dialog which returns cropped bytes (Uint8List) or null.
  Future<Uint8List?> _showSquareCropDialog(Uint8List imageData) async {
  return showDialog<Uint8List?>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) {
      bool cropping = false;
      void Function(void Function())? setStateDialog;

      return StatefulBuilder(
        builder: (context, setStateLocal) {
          setStateDialog = setStateLocal;

          return AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            title: const Text(
              'Crop avatar',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),

            content: SizedBox(
              width: MediaQuery.of(context).size.width * 0.85,
              height: MediaQuery.of(context).size.height * 0.55,
              child: Column(
                children: [
                  // ✅ FIXED: NO Expanded inside scroll
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Crop(
                        controller: _cropController,
                        image: imageData,
                        aspectRatio: 1.0,
                        withCircleUi: true, // better for profile
                        baseColor: Colors.black,
                        maskColor: Colors.black.withOpacity(0.5),
                        onCropped: (result) {
                          try {
                            if (result is CropSuccess) {
                              final Uint8List bytes =
                                  result.croppedImage;

                              setStateDialog?.call(() => cropping = false);
                              Navigator.of(dialogContext).pop(bytes);
                            } else {
                              setStateDialog?.call(() => cropping = false);
                              Navigator.of(dialogContext).pop(null);
                            }
                          } catch (_) {
                            setStateDialog?.call(() => cropping = false);
                            Navigator.of(dialogContext).pop(null);
                          }
                        },
                      ),
                    ),
                  ),

                  const SizedBox(height: 16),

                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.purple,
                            side: BorderSide(color: Colors.purple.shade200),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: cropping
                              ? null
                              : () => Navigator.of(dialogContext).pop(null),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.purple,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                          onPressed: cropping
                              ? null
                              : () {
                                  setStateDialog?.call(() => cropping = true);
                                  _cropController.crop();
                                },
                          child: cropping
                              ? const SizedBox(
                                  height: 18,
                                  width: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Crop & Use'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}
  
  
  
  void _startOtpTimer() {
    _otpTimer?.cancel(); // stop old timer

    setState(() {
      _otpSeconds = 30;
      _canResendOtp = false;
    });

    _otpTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_otpSeconds == 0) {
        setState(() => _canResendOtp = true);
        timer.cancel();
      } else {
        setState(() {
          _otpSeconds--;
        });
      }
    });
  }

  void _resendOtp() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text("OTP resent successfully 📩")));

    _startOtpTimer(); // restart countdown
  }

  bool _isPhoneLengthValid() {
    if (_countryCodes.isEmpty) return true;
    final selected = _countryCodes.firstWhere(
      (c) => c['dial_code'] == _dialCode,
      orElse: () => {'phone_length': '10'},
    );
    final int expected = int.tryParse(selected['phone_length'] ?? '10') ?? 10;
    return _phoneController.text.length == expected;
  }

  String _phoneLengthHint = '';

  void _updatePhoneHint() {
    if (_countryCodes.isEmpty) return;
    final selected = _countryCodes.firstWhere(
      (c) => c['dial_code'] == _dialCode,
      orElse: () => {'phone_length': '10', 'name': 'India'},
    );
    final expected = int.tryParse(selected['phone_length'] ?? '10') ?? 10;
    final name = selected['name'] ?? 'this country';
    final current = _phoneController.text.length;

    // limit input length
    if (_phoneController.text.length > expected) {
      _phoneController.text = _phoneController.text.substring(0, expected);
      _phoneController.selection = TextSelection.fromPosition(
        TextPosition(offset: _phoneController.text.length),
      );
    }

    // show hint if length is wrong
    if (current < expected) {
      setState(
        () => _phoneLengthHint = '⚠️ $name numbers must be $expected digits',
      );
    } else {
      setState(() => _phoneLengthHint = '');
    }
  }

  bool _shouldShowWarningIcon() {
    return !_isPhoneLengthValid();
  }

  // Address controllers
  late TextEditingController _addrLine1Ctrl;
  late TextEditingController _areaStreetVillageCtrl;
  late TextEditingController _landmarkCtrl;
  late TextEditingController _pincodeCtrl;
  late TextEditingController _cityCtrl;

  // City is auto-filled from the PIN code lookup below — never typed
  // directly, so the two can never silently disagree with each other.
  Timer? _pincodeDebounce;
  bool _pincodeLookupInFlight = false;
  String? _pincodeLookupError;

  // Country -> State cascade: the State list shown depends on which
  // Country is selected. India's list is instant (no network call);
  // other countries are looked up. Re-fetched whenever Country
  // changes.
  List<String> _statesForCountry = const [];
  bool _loadingStates = false;

  // City autocomplete, scoped to whichever State/District is
  // currently selected — typing shows real matching towns/localities
  // (major places only, tiny hamlets filtered out server-side).
  final FocusNode _cityFocus = FocusNode();
  Timer? _cityDebounce;
  List<Map<String, dynamic>> _citySuggestions = [];
  bool _showCitySuggestions = false;
  int _cityHighlightedIndex = -1;

  // State -> District cascade. Only Tamil Nadu has a real hardcoded
  // list right now (this app's primary use case) — other states
  // fall back to a free-text field rather than a broken-looking
  // empty dropdown.
  List<String> _districtsForState = const [];
  bool _loadingDistricts = false;
  String _districtValue = (userProfile.value['district'] ?? '').toString();
  final TextEditingController _districtFreeTextCtrl = TextEditingController();

  String _countryValue = _safeCountry(userProfile.value['country']);
  String _stateValue = _safeState(userProfile.value['state']);

  static String _safeState(dynamic v) {
    final up = (v ?? '').toString().trim().toUpperCase();
    return _indianStates.contains(up) ? up : 'TAMIL NADU';
  }

  static String _safeCountry(dynamic v) {
    final c = (v ?? '').toString().trim();
    return c.isEmpty ? 'India' : c;
  }

  String _dialCode = userProfile.value['dialCode'];
  bool _phoneVerified = true;
  List<Map<String, String>> _countryCodes = [];

  // States list (India). Extend as needed.
  static const List<String> _indianStates = [
    'ANDHRA PRADESH',
    'ARUNACHAL PRADESH',
    'ASSAM',
    'BIHAR',
    'CHHATTISGARH',
    'DELHI',
    'GOA',
    'GUJARAT',
    'HARYANA',
    'HIMACHAL PRADESH',
    'JAMMU & KASHMIR',
    'JHARKHAND',
    'KARNATAKA',
    'KERALA',
    'MADHYA PRADESH',
    'MAHARASHTRA',
    'MANIPUR',
    'MEGHALAYA',
    'MIZORAM',
    'NAGALAND',
    'ODISHA',
    'PUNJAB',
    'RAJASTHAN',
    'SIKKIM',
    'TAMIL NADU',
    'TELANGANA',
    'TRIPURA',
    'UTTAR PRADESH',
    'UTTARAKHAND',
    'WEST BENGAL',
    'PUDUCHERRY',
    'LADAKH',
    'ANDAMAN & NICOBAR',
    'CHANDIGARH',
    'DADRA & NAGAR HAVELI AND DAMAN & DIU',
    'LAKSHADWEEP',
  ];

  @override
  void initState() {
    super.initState();

    // Profile
    _nameController = TextEditingController(text: userProfile.value['name']);
    _emailController = TextEditingController(text: userProfile.value['email']);
    _phoneController = TextEditingController(text: userProfile.value['phone']);
    _locationController = TextEditingController(
      text: userProfile.value['location'],
    );

    // Address
    _addrLine1Ctrl = TextEditingController(
      text: userProfile.value['addressLine1'] ?? '',
    );
    _areaStreetVillageCtrl = TextEditingController(
      text: userProfile.value['areaStreetVillage'] ?? '',
    );
    _landmarkCtrl = TextEditingController(
      text: userProfile.value['landmark'] ?? '',
    );
    _pincodeCtrl = TextEditingController(
      text: userProfile.value['pincode'] ?? '',
    );
    _cityCtrl = TextEditingController(text: userProfile.value['city'] ?? '');
    _pincodeCtrl.addListener(_onPincodeChanged);
    _cityCtrl.addListener(_onCityChanged);
    _cityFocus.addListener(() {
      if (!_cityFocus.hasFocus) {
        // Delayed hide — a mouse click on a suggestion also unfocuses
        // the field at nearly the same instant; hiding immediately
        // can remove the list before its own onTap finishes firing.
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted && !_cityFocus.hasFocus) {
            setState(() => _showCitySuggestions = false);
          }
        });
      }
    });
    _loadStatesForCountry(_countryValue);

    _loadCountryCodes();
    _refreshFromServer(); // ensures correct data even if opened directly
    // (e.g. Settings → Profile Settings, skipping the You tab entirely).
  }

  void _onPincodeChanged() {
    final code = _pincodeCtrl.text.trim();
    _pincodeDebounce?.cancel();
    if (code.length != 6) {
      // Not a complete PIN code yet — don't show a stale error while
      // the person is still typing.
      if (_pincodeLookupError != null || _pincodeLookupInFlight) {
        setState(() {
          _pincodeLookupError = null;
          _pincodeLookupInFlight = false;
        });
      }
      return;
    }
    _pincodeDebounce = Timer(const Duration(milliseconds: 400), () async {
      setState(() {
        _pincodeLookupInFlight = true;
        _pincodeLookupError = null;
      });
      final result = await GeoApi.lookupPincode(code);
      if (!mounted || _pincodeCtrl.text.trim() != code) return; // stale
      setState(() {
        _pincodeLookupInFlight = false;
        if (result != null && (result['city'] ?? '').toString().isNotEmpty) {
          // Convenience fill only — City is primarily driven by the
          // suggestion box above (which now comes before Pincode in
          // the form), so don't clobber something already chosen.
          if (_cityCtrl.text.trim().isEmpty) {
            _cityCtrl.text = result['city'].toString();
          }
          final dist = (result['district'] ?? '').toString();
          if (dist.isNotEmpty && _districtValue.isEmpty) {
            _districtValue = dist;
          }
          final st = (result['state'] ?? '').toString().trim().toUpperCase();
          if (st.isNotEmpty && _statesForCountry.contains(st)) {
            _stateValue = st;
          }
        } else {
          _pincodeLookupError = 'PIN code not found — check and try again.';
        }
      });
    });
  }

  Widget _pincodeField() {
    return TextField(
      controller: _pincodeCtrl,
      keyboardType: TextInputType.number,
      inputFormatters: [
        FilteringTextInputFormatter.digitsOnly,
        LengthLimitingTextInputFormatter(10),
      ],
      decoration: InputDecoration(
        labelText: "Pincode",
        border: const OutlineInputBorder(),
        helperText: _pincodeLookupError,
        helperStyle: const TextStyle(color: Colors.red, fontSize: 12),
        suffixIcon: _pincodeLookupInFlight
            ? const Padding(
                padding: EdgeInsets.all(14),
                child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
              )
            : null,
      ),
    );
  }

  Future<void> _loadStatesForCountry(String country) async {
    setState(() => _loadingStates = true);
    final states = await GeoApi.getStatesForCountry(country);
    if (!mounted) return;
    setState(() {
      _loadingStates = false;
      _statesForCountry = states;
      // If the currently-picked state isn't valid for this country
      // (e.g. switched from India to another country), fall back to
      // the first available one rather than leaving a stale mismatch.
      if (states.isNotEmpty && !states.contains(_stateValue)) {
        _stateValue = states.first;
      }
    });
    _loadDistrictsForState(_stateValue);
  }

  Future<void> _loadDistrictsForState(String state) async {
    setState(() => _loadingDistricts = true);
    final districts = await GeoApi.getDistrictsForState(state);
    if (!mounted) return;
    setState(() {
      _loadingDistricts = false;
      _districtsForState = districts;
      // Only reset the picked district if it's genuinely invalid for
      // this state — don't clobber a value someone already chose.
      if (districts.isNotEmpty && !districts.contains(_districtValue)) {
        _districtValue = '';
      }
    });
  }

  void _onCountryChanged(String country) {
    setState(() {
      _countryValue = country;
      _cityCtrl.clear();
      _districtValue = '';
    });
    _loadStatesForCountry(country);
  }

  Widget _districtField() {
    if (_loadingDistricts) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 14),
        child: Row(
          children: [
            SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 10),
            Text('Loading districts…', style: TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    if (_districtsForState.isNotEmpty) {
      // Case-insensitive match against what might have come back from
      // an auto-fill (pincode/city suggestion) in a different case.
      final matched = _districtsForState.firstWhere(
        (d) => d.toUpperCase() == _districtValue.toUpperCase(),
        orElse: () => '',
      );
      return DropdownButtonFormField<String>(
        initialValue: matched.isEmpty ? null : matched,
        decoration: const InputDecoration(
          labelText: "District",
          border: OutlineInputBorder(),
          isDense: true,
          contentPadding:
              EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        ),
        hint: const Text("Select district", style: TextStyle(fontSize: 14)),
        onChanged: (v) {
          if (v == null) return;
          setState(() {
            _districtValue = v;
            _cityCtrl.clear();
          });
        },
        items: _districtsForState.map((d) {
          return DropdownMenuItem(
            value: d,
            child: Text(d, style: const TextStyle(fontSize: 14)),
          );
        }).toList(),
      );
    }

    // No hardcoded list for this state yet — free text, matching the
    // backend's honest "no guessed data" fallback rather than
    // showing a broken-looking empty dropdown.
    return TextField(
      controller: _districtFreeTextCtrl..text = _districtValue,
      onChanged: (v) => _districtValue = v,
      decoration: const InputDecoration(
        labelText: "District",
        border: OutlineInputBorder(),
      ),
    );
  }

  void _onCityChanged() {
    final query = _cityCtrl.text.trim();
    _cityDebounce?.cancel();
    if (query.length < 3) {
      setState(() {
        _citySuggestions = [];
        _showCitySuggestions = false;
        _cityHighlightedIndex = -1;
      });
      return;
    }
    _cityDebounce = Timer(const Duration(milliseconds: 350), () async {
      final results =
          await GeoApi.suggestCities(query,
              state: _stateValue, district: _districtValue);
      if (!mounted || _cityCtrl.text.trim() != query) return; // stale
      setState(() {
        _citySuggestions = results;
        _showCitySuggestions = results.isNotEmpty && _cityFocus.hasFocus;
        _cityHighlightedIndex = -1;
      });
    });
  }

  void _selectCitySuggestion(Map<String, dynamic> s) {
    _cityCtrl.text = (s['city'] ?? '').toString();
    setState(() {
      _districtValue = (s['district'] ?? '').toString();
      _showCitySuggestions = false;
      _cityHighlightedIndex = -1;
    });
    // A specific pincode came with this suggestion — offer it, but
    // don't fight the person if they'd already typed one themselves.
    final pin = (s['pincode'] ?? '').toString();
    if (pin.isNotEmpty && _pincodeCtrl.text.trim().isEmpty) {
      _pincodeCtrl.text = pin;
    }
    _cityFocus.unfocus();
  }

  KeyEventResult _handleCityKeyEvent(FocusNode node, KeyEvent event) {
    if (!_showCitySuggestions || _citySuggestions.isEmpty) {
      return KeyEventResult.ignored;
    }
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _cityHighlightedIndex =
          (_cityHighlightedIndex + 1) % _citySuggestions.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _cityHighlightedIndex =
          (_cityHighlightedIndex - 1 + _citySuggestions.length) %
              _citySuggestions.length);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_cityHighlightedIndex >= 0 &&
          _cityHighlightedIndex < _citySuggestions.length) {
        _selectCitySuggestion(_citySuggestions[_cityHighlightedIndex]);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Widget _cityField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Focus(
          onKeyEvent: _handleCityKeyEvent,
          child: TextField(
            controller: _cityCtrl,
            focusNode: _cityFocus,
            decoration: InputDecoration(
              labelText: "Town/City",
              helperText: _districtValue.isNotEmpty
                  ? "District: $_districtValue"
                  : "Start typing to see suggestions",
              helperStyle: const TextStyle(fontSize: 12),
              border: const OutlineInputBorder(),
            ),
            onTap: () {
              if (_citySuggestions.isNotEmpty) {
                setState(() => _showCitySuggestions = true);
              }
            },
          ),
        ),
        if (_showCitySuggestions)
          Container(
            margin: const EdgeInsets.only(top: 4),
            constraints: const BoxConstraints(maxHeight: 220),
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border.all(color: Colors.grey.shade300),
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 3)),
              ],
            ),
            child: ListView.separated(
              shrinkWrap: true,
              padding: const EdgeInsets.symmetric(vertical: 4),
              itemCount: _citySuggestions.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 1, color: Colors.grey.shade100),
              itemBuilder: (_, i) {
                final s = _citySuggestions[i];
                final selected = i == _cityHighlightedIndex;
                final subtitle = [s['district'], s['state']]
                    .where((x) => (x ?? '').toString().isNotEmpty)
                    .join(', ');
                return ListTile(
                  dense: true,
                  tileColor:
                      selected ? Colors.blue.shade50 : Colors.transparent,
                  leading: Icon(Icons.location_city,
                      size: 18,
                      color: selected ? Colors.blue : Colors.black45),
                  title: Text((s['city'] ?? '').toString(),
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight:
                              selected ? FontWeight.w600 : FontWeight.normal)),
                  subtitle: subtitle.isEmpty
                      ? null
                      : Text(subtitle, style: const TextStyle(fontSize: 11.5)),
                  onTap: () => _selectCitySuggestion(s),
                );
              },
            ),
          ),
      ],
    );
  }

  /// Re-pull the logged-in user's own profile and resync every field.
  /// Safe to call even if userProfile already had fresh data.
  Future<void> _refreshFromServer() async {
    await loadProfileFromServer();
    if (!mounted) return;
    final p = userProfile.value;
    setState(() {
      _nameController.text = (p['name'] ?? '').toString();
      _emailController.text = (p['email'] ?? '').toString();
      _phoneController.text = (p['phone'] ?? '').toString();
      _locationController.text = (p['location'] ?? '').toString();
      _addrLine1Ctrl.text = (p['addressLine1'] ?? '').toString();
      _areaStreetVillageCtrl.text = (p['areaStreetVillage'] ?? '').toString();
      _landmarkCtrl.text = (p['landmark'] ?? '').toString();
      _pincodeCtrl.text = (p['pincode'] ?? '').toString();
      _cityCtrl.text = (p['city'] ?? '').toString();
      _districtValue = (p['district'] ?? '').toString();
      _countryValue = _safeCountry(p['country']);
      _stateValue = _safeState(p['state']);
    });
  }

  Future<void> _loadCountryCodes() async {
    final data = await rootBundle.loadString('assets/country_codes.json');
    final List<dynamic> jsonResult = json.decode(data);
    setState(() {
      _countryCodes = jsonResult
          .map(
            (e) => {
              'name': e['name'] as String,
              'dial_code': e['dial_code'] as String,
              'code': e['code'] as String,
              'phone_length': e['phone_length']?.toString() ?? '10',
            },
          )
          .toList();
    });
  }

  Future<void> _handleCameraPermission() async {
    final cameraStatus = await Permission.camera.request();
    if (cameraStatus.isDenied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Camera access denied. Opening settings...'),
          ),
        );
      }
      await openAppSettings();
    }
  }

  // ✅ Gallery without permission; Camera asks permission
  Future<void> _chooseImageSource() async {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Wrap(
          children: [
            // Camera — ask permission here only
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Colors.blue),
              title: const Text('Take Photo'),
              onTap: () async {
                Navigator.pop(context);
                if (!kIsWeb) {
                  await _handleCameraPermission();
                }
                final picked = await _picker.pickImage(
                  source: ImageSource.camera,
                  imageQuality: 80,
                );
                if (picked != null) {
                  final bytes = await picked.readAsBytes();

                  // open crop dialog (square 1:1)
                  final Uint8List? cropped = await _showSquareCropDialog(bytes);

                  if (cropped == null) {
                    // user cancelled crop -> do nothing
                    return;
                  }

                  if (kIsWeb) {
                    // on web: set memory bytes for preview and profile
                    setState(() {
                      userProfile.value = {
                        ...userProfile.value,
                        'webImageBytes': cropped,
                        'avatar':
                            null, // keep avatar null on web (we use bytes)
                      };
                      _imageFile = null;
                    });
                    userProfile.notifyListeners();
                  } else {
                    // mobile: save cropped bytes to a temporary file and set _imageFile
                    try {
                      final dir = await getTemporaryDirectory();
                      final file = File(
                        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.png',
                      );
                      await file.writeAsBytes(cropped);
                      setState(() {
                        _imageFile = file;
                        userProfile.value = {
                          ...userProfile.value,
                          'avatar': file.path,
                          'webImageBytes': userProfile.value['webImageBytes'],
                        };
                      });
                      userProfile.notifyListeners();
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Failed to save cropped image'),
                          ),
                        );
                      }
                    }
                  }
                  // Persist to the server — the source of truth every
                  // other screen (Home, Chat, Bookings) actually reads.
                  await _uploadAndSyncAvatar(cropped);
                }
              },
            ),

            // Gallery — NO permission checks
            ListTile(
              leading: const Icon(Icons.photo_library, color: Colors.green),
              title: const Text('Choose from Gallery'),
              onTap: () async {
                Navigator.pop(context);
                final picked = await _picker.pickImage(
                  source: ImageSource.gallery,
                  imageQuality: 80,
                );
                if (picked != null) {
                  final bytes = await picked.readAsBytes();

                  // open crop dialog (square 1:1)
                  final Uint8List? cropped = await _showSquareCropDialog(bytes);

                  if (cropped == null) {
                    // user cancelled crop -> do nothing
                    return;
                  }

                  if (kIsWeb) {
                    // on web: set memory bytes for preview and profile
                    setState(() {
                      userProfile.value = {
                        ...userProfile.value,
                        'webImageBytes': cropped,
                        'avatar': null,
                      };
                      _imageFile = null;
                    });
                    userProfile.notifyListeners();
                  } else {
                    // mobile: save cropped bytes to a temporary file and set _imageFile
                    try {
                      final dir = await getTemporaryDirectory();
                      final file = File(
                        '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.png',
                      );
                      await file.writeAsBytes(cropped);
                      setState(() {
                        _imageFile = file;
                        userProfile.value = {
                          ...userProfile.value,
                          'avatar': file.path,
                          'webImageBytes': userProfile.value['webImageBytes'],
                        };
                      });
                      userProfile.notifyListeners();
                    } catch (e) {
                      if (mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Failed to save cropped image'),
                          ),
                        );
                      }
                    }
                  }
                  // Persist to the server — the source of truth every
                  // other screen (Home, Chat, Bookings) actually reads.
                  await _uploadAndSyncAvatar(cropped);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  // 🔐 OTP Verification Dialog
  void _showOtpDialog() {
    _otpTimer?.cancel(); // stop old ones

    VoidCallback? dialogSetState; // <--- save reference to dialog's setState

    // Start timer AFTER dialogSetState is assigned
    void startTimer() {
      _otpSeconds = 30;
      _canResendOtp = false;

      _otpTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_otpSeconds == 0) {
          timer.cancel();
          _canResendOtp = true;

          // update ONLY the dialog
          if (dialogSetState != null) dialogSetState!();
          return;
        }

        _otpSeconds--;

        // update ONLY the dialog
        if (dialogSetState != null) dialogSetState!();
      });
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            dialogSetState = () =>
                setStateDialog(() {}); // <--- store reference

            return AlertDialog(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              title: const Text(
                "🔐 Verify Phone Number",
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "Enter the 4-digit OTP sent to $_dialCode ${_phoneController.text}",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),

                  OtpTextField(
                    numberOfFields: 4,
                    filled: true,
                    fillColor: Colors.grey.shade200,
                    showFieldAsBox: true,
                    fieldWidth: MediaQuery.of(context).size.width * 0.14,
                    onSubmit: (otp) {
                      _otpTimer?.cancel();
                      setState(() => _phoneVerified = true);
                      Navigator.pop(dialogContext);

                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text("Phone Verified Successfully ✅"),
                        ),
                      );
                    },
                  ),

                  const SizedBox(height: 18),

                  (!_canResendOtp)
                      ? Text(
                          "Didn’t receive code? Resend after ${_otpSeconds}s",
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        )
                      : TextButton(
                          onPressed: () {
                            startTimer(); // restart timer correctly
                            setStateDialog(() {}); // update dialog
                          },
                          child: const Text(
                            "Resend OTP",
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.blue,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    _otpTimer?.cancel();
                    Navigator.pop(dialogContext);
                  },
                  child: const Text("Cancel"),
                ),
              ],
            );
          },
        );
      },
    );

    // Start timer AFTER dialog is created
    Future.delayed(Duration.zero, startTimer);
  }

  /// Open full-screen map picker
  Future<void> _openMapPicker() async {
    final result = await Navigator.push<Map<String, dynamic>>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationPickerScreen(
          initialLat: userProfile.value['latitude'],
          initialLon: userProfile.value['longitude'],
        ),
      ),
    );

    if (!mounted || result == null) return;

    final placeName = result['address']?.toString().trim() ?? '';
    final lat = result['latitude'];
    final lon = result['longitude'];

    setState(() {
      _locationController.text = placeName.isNotEmpty
          ? placeName
          : "Lat: ${lat.toStringAsFixed(5)}, Lon: ${lon.toStringAsFixed(5)}";
      userProfile.value['latitude'] = lat;
      userProfile.value['longitude'] = lon;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("📍 Location selected successfully!")),
    );
  }

  /// Use GPS + reverse geocoding to autofill address fields
  Future<void> _useMyLocationToFillAddress() async {
    // Ask permissions if required
    LocationPermission perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      perm = await Geolocator.requestPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permission denied')),
        );
        return;
      }
    }

    final pos = await Geolocator.getCurrentPosition();
    // Reverse-geocode via our own backend — the `geocoding` plugin has
    // no Web implementation and silently failed on Flutter Web,
    // which is why this used to leave fields blank or fall through
    // to nothing useful in a browser.
    final result = await GeoApi.reverseGeocodeFull(pos.latitude, pos.longitude);
    if (!mounted) return;
    if (result == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not resolve an address for this location.')));
      return;
    }
    final c = Map<String, dynamic>.from(result['components'] ?? {});

    final addr1 = [c['name'], c['street'], c['sublocality']]
        .where((e) => (e ?? '').toString().trim().isNotEmpty)
        .join(', ');

    setState(() {
      _countryValue = (c['country'] ?? 'India').toString();
      _stateValue = ((c['state'] ?? _stateValue) as String).toUpperCase();
      _cityCtrl.text = (c['locality'] ?? _cityCtrl.text).toString();
      _pincodeCtrl.text = (c['postal_code'] ?? _pincodeCtrl.text).toString();
      _addrLine1Ctrl.text = addr1.isEmpty ? _addrLine1Ctrl.text : addr1;
      _areaStreetVillageCtrl.text =
          (c['sub_administrative_area'] ?? _areaStreetVillageCtrl.text)
              .toString();
      // landmark left to user
      _locationController.text =
          (result['address'] ?? '${c['locality'] ?? ''}, ${c['state'] ?? ''}')
              .toString()
              .trim()
              .replaceAll(RegExp(r'^,|,\s*$'), '');
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Address filled from current location')),
    );
  }

  Future<void> _saveProfile() async {
    if (!_phoneVerified) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            "⚠️ Please verify your new phone number before saving.",
          ),
        ),
      );
      return;
    }

    final name = _nameController.text.trim();
    if (name.length < 2 || !RegExp(r'^[a-zA-Z\s.]+$').hasMatch(name)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text("Please enter a valid name (letters only).")),
      );
      return;
    }

    final email = _emailController.text.trim();
    if (email.isNotEmpty &&
        !RegExp(r'^[a-zA-Z0-9.\_%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}$')
            .hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                "Please enter a valid email address (e.g. name@example.com).")),
      );
      return;
    }

    final pincode = _pincodeCtrl.text.trim();
    if (pincode.isNotEmpty && !RegExp(r'^[0-9]{4,10}$').hasMatch(pincode)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Please enter a valid pincode.")),
      );
      return;
    }

    final selectedCountry = _countryCodes.firstWhere(
      (c) => c['dial_code'] == _dialCode,
      orElse: () => {'phone_length': '10'},
    );
    final int expectedLength =
        int.tryParse(selectedCountry['phone_length'] ?? '10') ?? 10;

    if (_phoneController.text.length != expectedLength) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            "Phone number must be exactly $expectedLength digits for this country.",
          ),
        ),
      );
      return;
    }

    // Merge changes back to userProfile
    userProfile.value = {
      ...userProfile.value,
      // profile
      'name': _nameController.text.trim(),
      'email': _emailController.text.trim(),
      'phone': _phoneController.text.trim(),
      'dialCode': _dialCode,
      'location': _locationController.text.trim(),
      'rating': userProfile.value['rating'],
      'avatar': _imageFile?.path ?? userProfile.value['avatar'],
      // keep web image bytes if set
      'webImageBytes': userProfile.value['webImageBytes'],

      // address
      'country': _countryValue.trim(),
      'addressLine1': _addrLine1Ctrl.text.trim(),
      'areaStreetVillage': _areaStreetVillageCtrl.text.trim(),
      'landmark': _landmarkCtrl.text.trim(),
      'pincode': _pincodeCtrl.text.trim(),
      'city': _cityCtrl.text.trim(),
      'district': _districtValue.trim(),
      'state': _stateValue.trim(),

      'latitude': userProfile.value['latitude'],
      'longitude': userProfile.value['longitude'],
    };

    userProfile.notifyListeners();

    // 🔄 persist to the backend
    final res = await saveProfileToServer();

    if (mounted) {
      String message;
      if (res.success) {
        message = 'Profile updated successfully ✅';
      } else if (res.isOffline) {
        // Genuine connectivity problem — the value might still sync
        // later once the app is back online.
        message = 'Saved locally — will sync when connection is back';
      } else {
        // The server explicitly rejected this (e.g. phone/email
        // already used, invalid format) — it will NOT sync later on
        // its own, so don't claim otherwise. Revert the optimistic
        // local change so the UI doesn't keep showing a value that
        // was never actually saved.
        message = res.message.isNotEmpty
            ? res.message
            : 'Could not save your changes — please check and try again.';
        await loadProfileFromServer();
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    ImageProvider? previewAvatar;
    final avatarUrl = ApiConfig.resolveMediaUrl(userProfile.value['avatarUrl']?.toString());
    if (kIsWeb && userProfile.value['webImageBytes'] != null) {
      previewAvatar = MemoryImage(userProfile.value['webImageBytes']);
    } else if (_imageFile != null) {
      previewAvatar = FileImage(_imageFile!);
    } else if (userProfile.value['avatar'] != null &&
        File(userProfile.value['avatar']).existsSync()) {
      previewAvatar = FileImage(File(userProfile.value['avatar']));
    } else if (avatarUrl != null) {
      previewAvatar = NetworkImage(avatarUrl);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          "Edit Profile",
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
        centerTitle: true,
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
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
      body: Container(
        width: double.infinity,
        color: const Color(0xFFF7F9FC), // soft bg
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            children: [
              // ==== Profile Card ====
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Avatar with edit + remove controls
                      // Avatar with view/edit/remove controls
                      Center(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // tappable avatar or "add photo" that either views (if exists) or opens picker
                            GestureDetector(
                              onTap: previewAvatar != null
                                  ? _viewAvatar
                                  : _chooseImageSource,
                              child: CircleAvatar(
                                radius: kIsWeb ? 60 : 50,
                                backgroundColor: Colors.blue[100],
                                backgroundImage: previewAvatar,
                                child: previewAvatar == null
                                    ? const Icon(
                                        Icons.add_a_photo,
                                        size: 34,
                                        color: Colors.blue,
                                      )
                                    : null,
                              ),
                            ),

                            // top-right edit icon (small)
                            Positioned(
                              right: (kIsWeb ? 8 : 6),
                              top: (kIsWeb ? 8 : 6),
                              child: GestureDetector(
                                onTap: _chooseImageSource,
                                child: Container(
                                  width: 34,
                                  height: 34,
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.12),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.edit,
                                    size: 18,
                                    color: Colors.blueAccent,
                                  ),
                                ),
                              ),
                            ),

                            // bottom-right remove icon (visible only when there is an avatar)
                            if (previewAvatar != null)
                              Positioned(
                                right: (kIsWeb ? 6 : 4),
                                bottom: (kIsWeb ? 6 : 4),
                                child: GestureDetector(
                                  onTap: () async {
                                    // show same remove confirmation as _removeAvatar
                                    await _removeAvatar();
                                  },
                                  child: Container(
                                    width: 34,
                                    height: 34,
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(
                                          color: Colors.black.withOpacity(0.12),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const Icon(
                                      Icons.delete_outline,
                                      size: 18,
                                      color: Colors.redAccent,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),

                      // Name
                      TextField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: "Full Name (First and Last name)",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Email
                      TextField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: "Email ID",
                          hintText: "name@example.com",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Phone Row (Country dial + phone + verify)
                      LayoutBuilder(
                        builder: (context, constraints) {
                          final isWide = constraints.maxWidth > 550;

                          return isWide
                              ? Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // COUNTRY DROPDOWN
                                    Expanded(
                                      flex: 3,
                                      child: _countryCodes.isEmpty
                                          ? const SizedBox(
                                              height: 50,
                                              child: Center(
                                                child:
                                                    CircularProgressIndicator(),
                                              ),
                                            )
                                          : DropdownButtonFormField<String>(
                                              isExpanded: true,
                                              menuMaxHeight: 300,
                                              decoration: const InputDecoration(
                                                labelText: "Country",
                                                border: OutlineInputBorder(),
                                                contentPadding:
                                                    EdgeInsets.symmetric(
                                                      horizontal: 10,
                                                    ),
                                              ),
                                              value: _dialCode,
                                              onChanged: (v) => setState(
                                                () => _dialCode = v!,
                                              ),
                                              items: _countryCodes.map((c) {
                                                return DropdownMenuItem<String>(
                                                  value: c['dial_code'],
                                                  child: Text(
                                                    "${c['name']} (${c['dial_code']})",
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    maxLines: 1,
                                                  ),
                                                );
                                              }).toList(),
                                            ),
                                    ),
                                    const SizedBox(width: 6),

                                    // PHONE TEXTFIELD
                                    Expanded(
                                      flex: 4,
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          TextField(
                                            controller: _phoneController,
                                            keyboardType: TextInputType.phone,
                                            inputFormatters: [
                                              FilteringTextInputFormatter
                                                  .digitsOnly,
                                            ],
                                            maxLength:
                                                int.tryParse(
                                                  _countryCodes.firstWhere(
                                                        (c) =>
                                                            c['dial_code'] ==
                                                            _dialCode,
                                                        orElse: () => {
                                                          'phone_length': '10',
                                                        },
                                                      )['phone_length'] ??
                                                      '10',
                                                ) ??
                                                10,
                                            onChanged: (_) {
                                              _updatePhoneHint();
                                              setState(
                                                () => _phoneVerified = false,
                                              );
                                            },
                                            decoration: InputDecoration(
                                              labelText: "Mobile number",
                                              counterText: "",
                                              border:
                                                  const OutlineInputBorder(),
                                              suffixIcon: _phoneVerified
                                                  ? const Icon(
                                                      Icons.verified,
                                                      color: Colors.green,
                                                    )
                                                  : _isPhoneLengthValid()
                                                  ? const Icon(
                                                      Icons
                                                          .check_circle_outline,
                                                      color: Colors.grey,
                                                    )
                                                  : const Icon(
                                                      Icons.warning_amber,
                                                      color: Colors.red,
                                                    ),
                                            ),
                                          ),
                                          if (_phoneLengthHint.isNotEmpty)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                                left: 4,
                                              ),
                                              child: Text(
                                                _phoneLengthHint,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: Colors.redAccent,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 6),

                                    // VERIFY BUTTON
                                    Expanded(
                                      flex: 2,
                                      child: SizedBox(
                                        height: 50,
                                        child: ElevatedButton(
                                          onPressed: _isPhoneLengthValid()
                                              ? _showOtpDialog
                                              : null,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor:
                                                _isPhoneLengthValid()
                                                ? Colors.blue
                                                : Colors.grey.shade400,
                                            foregroundColor: Colors.white,
                                            shape: const StadiumBorder(),
                                          ),
                                          child: const FittedBox(
                                            child: Text("Verify"),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                )
                              : Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // COUNTRY DROPDOWN (added here)
                                    _countryCodes.isEmpty
                                        ? const SizedBox(
                                            height: 50,
                                            child: Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            ),
                                          )
                                        : DropdownButtonFormField<String>(
                                            isExpanded: true,
                                            menuMaxHeight: 300,
                                            decoration: const InputDecoration(
                                              labelText: "Country",
                                              border: OutlineInputBorder(),
                                            ),
                                            value: _dialCode,
                                            onChanged: (v) =>
                                                setState(() => _dialCode = v!),
                                            items: _countryCodes.map((c) {
                                              return DropdownMenuItem<String>(
                                                value: c['dial_code'],
                                                child: Text(
                                                  "${c['name']} (${c['dial_code']})",
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              );
                                            }).toList(),
                                          ),
                                    const SizedBox(height: 12),

                                    // PHONE TEXTFIELD
                                    TextField(
                                      controller: _phoneController,
                                      keyboardType: TextInputType.phone,
                                      inputFormatters: [
                                        FilteringTextInputFormatter
                                            .digitsOnly,
                                      ],
                                      maxLength:
                                          int.tryParse(
                                            _countryCodes.firstWhere(
                                                  (c) =>
                                                      c['dial_code'] ==
                                                      _dialCode,
                                                  orElse: () => {
                                                    'phone_length': '10',
                                                  },
                                                )['phone_length'] ??
                                                '10',
                                          ) ??
                                          10,
                                      onChanged: (_) {
                                        _updatePhoneHint();
                                        setState(() => _phoneVerified = false);
                                      },
                                      decoration: InputDecoration(
                                        labelText: "Mobile number",
                                        counterText: "",
                                        border: const OutlineInputBorder(),
                                        suffixIcon: _phoneVerified
                                            ? const Icon(
                                                Icons.verified,
                                                color: Colors.green,
                                              )
                                            : _isPhoneLengthValid()
                                            ? const Icon(
                                                Icons.check_circle_outline,
                                                color: Colors.grey,
                                              )
                                            : const Icon(
                                                Icons.warning_amber,
                                                color: Colors.red,
                                              ),
                                      ),
                                    ),
                                    if (_phoneLengthHint.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(
                                          top: 4,
                                          left: 4,
                                        ),
                                        child: Text(
                                          _phoneLengthHint,
                                          style: const TextStyle(
                                            fontSize: 12,
                                            color: Colors.redAccent,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                    const SizedBox(height: 12),

                                    // VERIFY BUTTON
                                    SizedBox(
                                      width: double.infinity,
                                      height: 50,
                                      child: ElevatedButton(
                                        onPressed: _isPhoneLengthValid()
                                            ? _showOtpDialog
                                            : null,
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: _isPhoneLengthValid()
                                              ? Colors.blue
                                              : Colors.grey.shade400,
                                          foregroundColor: Colors.white,
                                          shape: const StadiumBorder(),
                                        ),
                                        child: const Text("Verify"),
                                      ),
                                    ),
                                  ],
                                );
                        },
                      ),

                      const SizedBox(height: 14),

                      // Quick location summary + map picker
                      TextField(
                        readOnly: true,
                        controller: _locationController,
                        decoration: InputDecoration(
                          labelText: "Location (summary)",
                          border: const OutlineInputBorder(),
                          suffixIcon: IconButton(
                            icon: const Icon(Icons.map),
                            onPressed: _openMapPicker,
                          ),
                        ),
                        maxLines: 2, // 👈 allows wrap but prevents overflow
                      ),
                    ],
                  ),
                ),
              ),

              // ==== Address Details Card ====
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                margin: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        "Address Details",
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 14),

                      // 1. Country
                      DropdownButtonFormField<String>(
                        initialValue: _countryValue,
                        decoration: const InputDecoration(
                          labelText: "Country",
                          border: OutlineInputBorder(),
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                        ),
                        onChanged: (v) {
                          if (v == null) return;
                          _onCountryChanged(v);
                        },
                        items: const [
                          'India',
                          'United States',
                          'United Kingdom',
                          'Canada',
                          'Australia',
                          'Germany',
                          'France',
                          'Japan',
                        ].map((e) {
                          return DropdownMenuItem(
                            value: e,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 220),
                              child: Text(
                                e,
                                overflow: TextOverflow.ellipsis,
                                maxLines: 1,
                                style: const TextStyle(fontSize: 14),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 12),

                      // 2. State
                      _loadingStates
                          ? const Padding(
                              padding: EdgeInsets.symmetric(vertical: 14),
                              child: Row(
                                children: [
                                  SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2)),
                                  SizedBox(width: 10),
                                  Text('Loading states…',
                                      style: TextStyle(fontSize: 13)),
                                ],
                              ),
                            )
                          : DropdownButtonFormField<String>(
                              initialValue: _statesForCountry.contains(_stateValue)
                                  ? _stateValue
                                  : (_statesForCountry.isNotEmpty
                                      ? _statesForCountry.first
                                      : null),
                              decoration: const InputDecoration(
                                labelText: "State",
                                border: OutlineInputBorder(),
                                isDense: true,
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 14,
                                ),
                              ),
                              onChanged: (v) {
                                if (v == null) return;
                                setState(() {
                                  _stateValue = v;
                                  _cityCtrl.clear();
                                  _districtValue = '';
                                });
                                _loadDistrictsForState(v);
                              },
                              items: _statesForCountry.map((s) {
                                return DropdownMenuItem(
                                  value: s,
                                  child: ConstrainedBox(
                                    constraints:
                                        const BoxConstraints(maxWidth: 220),
                                    child: Text(
                                      s,
                                      overflow: TextOverflow.ellipsis,
                                      maxLines: 1,
                                      style: const TextStyle(fontSize: 14),
                                    ),
                                  ),
                                );
                              }).toList(),
                            ),
                      const SizedBox(height: 12),

                      // 3. District — dropdown for Tamil Nadu (this
                      // app's primary use case), free-text fallback
                      // for states without a hardcoded list yet.
                      _districtField(),
                      const SizedBox(height: 12),

                      // 4. PIN Code — a convenience shortcut: typing
                      // a full 6-digit code auto-suggests City (and
                      // District/State, if still unset), same as
                      // typing "637301" resolving to Sankagiri.
                      _pincodeField(),
                      const SizedBox(height: 12),

                      // 5. Town / City — free-text with live
                      // suggestions scoped to State + District,
                      // major places only (small hamlets filtered
                      // out server-side).
                      _cityField(),
                      const SizedBox(height: 12),

                      // 6. Area / Street / Sector / Village
                      TextField(
                        controller: _areaStreetVillageCtrl,
                        decoration: const InputDecoration(
                          labelText: "Area, Street, Sector, Village",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // Landmark
                      TextField(
                        controller: _landmarkCtrl,
                        decoration: const InputDecoration(
                          labelText: "Landmark",
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),

                      // 7. Flat / House No. — last, as requested.
                      TextField(
                        controller: _addrLine1Ctrl,
                        decoration: const InputDecoration(
                          labelText:
                              "Flat, House no., Building, Company, Apartment",
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ==== Save Button ====
              // ==== Save Button ====
              // ==== Save Button ====
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _phoneController.text.trim().isEmpty
                      ? null
                      : _saveProfile,
                  icon: const Icon(Icons.save),
                  label: const Text("Save Changes"),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 50),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 30),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _otpTimer?.cancel();
    // no _cropController.dispose() - CropController has no dispose()
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _locationController.dispose();
    _addrLine1Ctrl.dispose();
    _areaStreetVillageCtrl.dispose();
    _landmarkCtrl.dispose();
    _pincodeDebounce?.cancel();
    _pincodeCtrl.removeListener(_onPincodeChanged);
    _pincodeCtrl.dispose();
    _cityDebounce?.cancel();
    _cityCtrl.removeListener(_onCityChanged);
    _cityFocus.dispose();
    _cityCtrl.dispose();
    _districtFreeTextCtrl.dispose();
    super.dispose();
  }
}

class GmsLocationIcon extends StatelessWidget {
  final Color color;
  const GmsLocationIcon({super.key, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 26,
      height: 26,
      child: CustomPaint(painter: _GmsLocationPainter(color)),
    );
  }
}

class _GmsLocationPainter extends CustomPainter {
  final Color color;
  _GmsLocationPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2;

    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.32;

    canvas.drawCircle(center, radius, paint);

    canvas.drawLine(
      Offset(center.dx, 0),
      Offset(center.dx, size.height * 0.23),
      paint,
    );

    canvas.drawLine(
      Offset(center.dx, size.height),
      Offset(center.dx, size.height * 0.77),
      paint,
    );

    canvas.drawLine(
      Offset(0, center.dy),
      Offset(size.width * 0.23, center.dy),
      paint,
    );

    canvas.drawLine(
      Offset(size.width, center.dy),
      Offset(size.width * 0.77, center.dy),
      paint,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}

///  Full-screen location picker with a search bar (OpenStreetMap)
class LocationPickerScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLon;

  const LocationPickerScreen({super.key, this.initialLat, this.initialLon});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen>
    with TickerProviderStateMixin {
  final MapController _mapController = MapController();
  late ll.LatLng _center;
  ll.LatLng? _selected;

  // UI + state
  final TextEditingController _searchCtrl = TextEditingController();
  bool _searching = false;
  List<Map<String, dynamic>> _searchResults = [];
  Timer? _debounce;

  // Location / GPS status checking
  bool _locationEnabled = true;
  Timer? _gpsTimer;

  // Shake animation for disabled-location tap
  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  // For temporarily showing a small loading indicator on the current-location button
  bool _gettingCurrent = false;

  @override
  void initState() {
    super.initState();

    // initial centre: if passed use that, otherwise fallback to Mumbai (19.0760,72.8777)
    if (widget.initialLat != null && widget.initialLon != null) {
      _center = ll.LatLng(widget.initialLat!, widget.initialLon!);
      _selected = _center;
    } else {
      _center = const ll.LatLng(19.0760, 72.8777);
    }

    // set up shake animation
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _shakeAnimation = TweenSequence<double>(
      [
        TweenSequenceItem(tween: Tween(begin: 0.0, end: -8.0), weight: 1),
        TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
        TweenSequenceItem(tween: Tween(begin: 8.0, end: -5.0), weight: 2),
        TweenSequenceItem(tween: Tween(begin: -5.0, end: 0.0), weight: 1),
      ],
    ).animate(CurvedAnimation(parent: _shakeController, curve: Curves.easeOut));

    // check location service status immediately and then periodically
    _checkLocationStatus();
    _gpsTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _checkLocationStatus(),
    );

    // handle enter key from keyboard
    _searchCtrl.addListener(_onSearchControllerChange);
  }

  // Keep search suggestions reactive: if user types quickly debounce the HTTP search
  void _onSearchControllerChange() {
    // we don't want to trigger if we programmatically change the text (but it's fine)
    _debounce?.cancel();
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) {
      setState(() {
        _searchResults.clear();
      });
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 350),
      () => _searchAndMove(fromDebounce: true),
    );
  }

  Future<void> _checkLocationStatus() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (mounted && enabled != _locationEnabled) {
        setState(() => _locationEnabled = enabled);
      } else if (mounted && _locationEnabled != enabled) {
        setState(() => _locationEnabled = enabled);
      }
    } catch (_) {
      // ignore
    }
  }

  Future<void> _ensureLocationPermissions() async {
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    // we don't force a particular result here; callers will handle failure
  }

  Future<void> _goToCurrent() async {
    if (_gettingCurrent) return;
    setState(() => _gettingCurrent = true);
    try {
      await _ensureLocationPermissions();
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.best,
      );
      final curr = ll.LatLng(pos.latitude, pos.longitude);
      if (mounted) {
        setState(() {
          _center = curr;
          _selected = curr;
        });
        // move map smoothly
        _mapController.move(curr, 16);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't get current location")),
        );
      }
    } finally {
      if (mounted) setState(() => _gettingCurrent = false);
    }
  }

  /// Main search function: calls OSM search endpoint and populates suggestions.
  /// If fromDebounce==false (explicit search button or enter), we automatically move to first result.
  Future<void> _searchAndMove({bool fromDebounce = false}) async {
    final query = _searchCtrl.text.trim();
    if (query.isEmpty) return;

    if (mounted) {
      setState(() {
        _searching = true;
        // keep existing results during search for smoother UI; clear only if response empty
      });
    }

    try {
      final uri = Uri.parse(
        'https://nominatim.openstreetmap.org/search?format=json&q=${Uri.encodeQueryComponent(query)}&limit=6&addressdetails=1',
      );
      final res = await http.get(uri, headers: {'User-Agent': 'GMS/1.0'});
      if (res.statusCode == 200) {
        final List data = jsonDecode(res.body);
        final parsed = data.cast<Map<String, dynamic>>();
        if (mounted) {
          setState(() {
            _searchResults = parsed;
          });
        }

        if (!fromDebounce && parsed.isNotEmpty) {
          // If the user explicitly pressed enter or tapped search, auto-move to first result
          final first = parsed.first;
          final lat = double.tryParse(first['lat']?.toString() ?? '');
          final lon = double.tryParse(first['lon']?.toString() ?? '');
          if (lat != null && lon != null) {
            final target = ll.LatLng(lat, lon);
            _mapController.move(target, 16);
            if (mounted) {
              setState(() {
                _center = target;
                _selected = target;
                _searchCtrl.text =
                    first['display_name']?.toString() ?? _searchCtrl.text;
                _searchResults.clear(); // hide dropdown after moving
              });
            }
          }
        }
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Search failed (server error)')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Search failed')));
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  /// Returns a readable address string and pops navigator with address + coords.
  Future<void> _confirmSelection() async {
    if (_selected == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please tap on the map to select a location.'),
          ),
        );
      }
      return;
    }

    final lat = _selected!.latitude;
    final lon = _selected!.longitude;

    String address = '';

    try {
      // Try OSM reverse first (fast and consistent)
      final osmUrl = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=jsonv2&lat=$lat&lon=$lon&addressdetails=1',
      );
      final osmRes = await http.get(osmUrl, headers: {'User-Agent': 'GMS/1.0'});
      if (osmRes.statusCode == 200) {
        final osmData = jsonDecode(osmRes.body);
        final display = osmData['display_name']?.toString();
        if (display != null && display.trim().isNotEmpty) {
          address = display.trim();
        }
      }

      // If OSM didn't provide good text, fallback to platform geocoding
      if (address.trim().isEmpty) {
        final placemarks = await placemarkFromCoordinates(lat, lon);
        if (placemarks.isNotEmpty) {
          final p = placemarks.first;
          final parts = [
            p.name,
            p.street,
            p.subLocality,
            p.locality,
            p.subAdministrativeArea,
            p.administrativeArea,
            p.postalCode,
            p.country,
          ].where((s) => (s ?? '').toString().trim().isNotEmpty).toList();
          address = parts.join(', ');
        }
      }

      // final fallback — never show raw coordinates to the user,
      // even if both OSM and the platform plugin fail.
      if (address.trim().isEmpty) {
        address = "Pinned location";
      }

      // Clean up repeated commas / spaces
      address = address
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(RegExp(r',\s*,+'), ',')
          .trim();

      if (!mounted) return;
      Navigator.pop(context, {
        'address': address,
        'latitude': lat,
        'longitude': lon,
      });
    } catch (e) {
      if (!mounted) return;
      final fallback =
          "Lat: ${lat.toStringAsFixed(5)}, Lon: ${lon.toStringAsFixed(5)}";
      Navigator.pop(context, {
        'address': fallback,
        'latitude': lat,
        'longitude': lon,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              "⚠️ Couldn't fetch readable address; returning coordinates.",
            ),
          ),
        );
      }
    }
  }

  /// Called when user taps an item in suggestions list
  void _onSuggestionTap(Map<String, dynamic> item) {
    final lat = double.tryParse(item['lat']?.toString() ?? '');
    final lon = double.tryParse(item['lon']?.toString() ?? '');
    final display = item['display_name']?.toString() ?? '';
    if (lat == null || lon == null) return;
    final target = ll.LatLng(lat, lon);
    _mapController.move(target, 16);
    setState(() {
      _center = target;
      _selected = target;
      _searchCtrl.text = display;
      _searchResults.clear();
    });
  }

  // Helper to build the custom marker widget (red pin + dot)
  Widget _buildPin() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // circle pin
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: Colors.red.shade600,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: const Center(
            child: Icon(Icons.place, color: Colors.white, size: 20),
          ),
        ),
        // small drop shadow / anchor
        Container(
          margin: const EdgeInsets.only(top: 6),
          width: 12,
          height: 10,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.25),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.15),
                blurRadius: 4,
                spreadRadius: 1,
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _gpsTimer?.cancel();
    _shakeController.dispose();
    _searchCtrl.removeListener(_onSearchControllerChange);
    _searchCtrl.dispose();
    // NOTE: CropController has no dispose method in this package version
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final markers = <Marker>[
      if (_selected != null)
        Marker(point: _selected!, width: 50, height: 70, child: _buildPin()),
    ];

    return Scaffold(
      appBar: AppBar(title: const Text("Select the Location")),
      body: Stack(
        children: [
          // Map
          FlutterMap(
            mapController: _mapController,
            options: MapOptions(
              initialCenter: _center,
              initialZoom: 14,
              onTap: (_, point) {
                // tap on map selects point and hides suggestions
                setState(() {
                  _selected = point;
                  _searchResults.clear();
                  // update search box to coords while user hasn't confirmed
                  _searchCtrl.text =
                      "Lat: ${point.latitude.toStringAsFixed(5)}, Lon: ${point.longitude.toStringAsFixed(5)}";
                });
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.gms',
              ),
              MarkerLayer(markers: markers),
            ],
          ),

          // Top search bar overlay
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Material(
              elevation: 4,
              borderRadius: BorderRadius.circular(28),
              color: Colors.white,
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) async {
                        // explicit search: do not treat as debounce
                        await _searchAndMove(fromDebounce: false);
                      },
                      decoration: InputDecoration(
                        hintText: 'Search place or address',
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                        suffixIcon: _searching
                            ? Padding(
                                padding: const EdgeInsets.all(12.0),
                                child: SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              )
                            : null,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search),
                    onPressed: () => _searchAndMove(fromDebounce: false),
                  ),
                ],
              ),
            ),
          ),

          // Suggestions dropdown (below the search)
          if (_searchResults.isNotEmpty)
            Positioned(
              top: 72, // just under the search bar
              left: 12,
              right: 12,
              child: Material(
                elevation: 6,
                borderRadius: BorderRadius.circular(10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 260),
                  child: ListView.separated(
                    shrinkWrap: true,
                    itemCount: _searchResults.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (context, i) {
                      final itm = _searchResults[i];
                      final title = (itm['display_name'] ?? '').toString();
                      final lat = double.tryParse(itm['lat']?.toString() ?? '');
                      final lon = double.tryParse(itm['lon']?.toString() ?? '');
                      return ListTile(
                        leading: const Icon(Icons.place_outlined),
                        title: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: (lat != null && lon != null)
                            ? Text(
                                '(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})',
                              )
                            : null,
                        onTap: () => _onSuggestionTap(itm),
                      );
                    },
                  ),
                ),
              ),
            ),

          // Bottom-right anchored buttons (SafeArea + Align - prevents shifting)
          Positioned.fill(
            child: SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16, bottom: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      AnimatedBuilder(
                        animation: _shakeController,
                        builder: (context, child) {
                          return Transform.translate(
                            offset: Offset(_shakeAnimation.value, 0),
                            child: child,
                          );
                        },
                        child: GestureDetector(
                          onTap: () async {
                            // if enabled: fetch current; else prompt to enable
                            if (_locationEnabled) {
                              _goToCurrent();
                            } else {
                              // shake + open location settings
                              _shakeController.forward(from: 0);
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Please enable device location (GPS)',
                                  ),
                                ),
                              );
                              await Geolocator.openLocationSettings();
                              // after user returns, re-check
                              await Future.delayed(
                                const Duration(milliseconds: 600),
                              );
                              _checkLocationStatus();
                            }
                          },
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(0.18),
                                  blurRadius: 8,
                                ),
                              ],
                            ),
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // main icon
                                if (_gettingCurrent)
                                  const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                else
                                  Icon(
                                    _locationEnabled
                                        ? Icons.my_location
                                        : Icons.location_off,
                                    color: _locationEnabled
                                        ? Colors.blueAccent
                                        : Colors.black45,
                                    size: 28,
                                  ),

                                // cross overlay when disabled (small subtle cross)
                                if (!_locationEnabled)
                                  Positioned(
                                    right: 8,
                                    top: 8,
                                    child: Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: Colors.red.shade600,
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: const Icon(
                                        Icons.close,
                                        size: 12,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Confirm button
                      SizedBox(
                        width: 56,
                        height: 56,
                        child: FloatingActionButton(
                          heroTag: "confirmLoc",
                          backgroundColor: Colors.green,
                          onPressed: _confirmSelection,
                          child: const Icon(Icons.check, color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Attribution bottom-right (keeps same place)
          Positioned(
            bottom: 6,
            right: 6,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.5),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: const Text(
                '© OpenStreetMap contributors | GMS App',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white70,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
