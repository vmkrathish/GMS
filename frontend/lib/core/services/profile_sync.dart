// ─────────────────────────────────────────────
// core/services/profile_sync.dart
//
// Invisible bridge between the You-page's local
// `userProfile` ValueNotifier (original design, untouched)
// and the GMS backend.
//
//   load(notifier)  → GET /users/me + my services → notifier
//   push(profile)   → PUT /users/me (all profile+address fields)
//   syncServices()  → replaces my listings to match
//                     primaryService + otherServices
// ─────────────────────────────────────────────
import 'package:flutter/foundation.dart';

import '../api/service_api.dart';
import '../api/user_api.dart';
import 'session_manager.dart';

class ProfileSync {
  static const int _generalCategoryId = 41; // 'General Services'

  // ── SERVER → LOCAL ──────────────────────────
  static Future<void> load(
      ValueNotifier<Map<String, dynamic>> notifier) async {
    final res = await UserApi.getMe();
    if (!res.success || res.data is! Map) return;

    final u = Map<String, dynamic>.from(res.data['user'] ?? {});
    if (u.isEmpty) return;

    notifier.value = {
      ...notifier.value,
      'name': u['name'] ?? '',
      'email': u['email'] ?? '',
      'phone': u['phone'] ?? '',
      'dialCode': (u['dial_code'] ?? '+91').toString(),
      'location': u['location_text'] ?? '',
      'country': (u['country'] ?? 'India').toString(),
      'addressLine1': u['address_line1'] ?? '',
      'areaStreetVillage': u['area_street_village'] ?? '',
      'landmark': u['landmark'] ?? '',
      'pincode': u['pincode'] ?? '',
      'city': u['city'] ?? '',
      'state': (u['state'] ?? '').toString(),
      'latitude': double.tryParse('${u['latitude']}'),
      'longitude': double.tryParse('${u['longitude']}'),
    };
    notifier.notifyListeners();
    SessionManager.saveUser(u);

    // My services → primaryService / otherServices
    final myId = int.tryParse('${u['id']}');
    if (myId == null) return;
    final sres = await ServiceApi.getServices(providerId: myId);
    if (!sres.success || sres.data is! Map) return;

    final services =
        List<Map<String, dynamic>>.from((sres.data['services'] ?? [])
            .map((e) => Map<String, dynamic>.from(e as Map)));
    if (services.isEmpty) return;

    String unitToType(dynamic unit) =>
        unit == 'per_hour' ? 'per hour' : 'per day';

    Map<String, dynamic>? primary;
    final others = <Map<String, String>>[];
    double bestRating = 0;

    for (final s in services) {
      final r = double.tryParse('${s['average_rating'] ?? 0}') ?? 0;
      if (r > bestRating) bestRating = r;
      final row = {
        'name': (s['title'] ?? '').toString(),
        'charge': '${s['price'] ?? ''}'.replaceAll(RegExp(r'\.00$'), ''),
        'type': unitToType(s['price_unit']),
      };
      if (primary == null &&
          (s['is_primary'] == 1 || s['is_primary'] == true)) {
        primary = row;
      } else {
        others.add(row.map((k, v) => MapEntry(k, v)));
      }
    }
    primary ??= others.isNotEmpty ? others.removeAt(0) : null;

    notifier.value = {
      ...notifier.value,
      if (primary != null) 'primaryService': primary,
      'otherServices': others,
      if (bestRating > 0) 'rating': bestRating.toStringAsFixed(1),
    };
    notifier.notifyListeners();
  }

  // ── LOCAL → SERVER (profile + address) ──────
  static Future<bool> push(Map<String, dynamic> p) async {
    final res = await UserApi.updateProfile({
      'name': p['name'] ?? '',
      'email': p['email'] ?? '',
      'dial_code': p['dialCode'] ?? '+91',
      'location_text': p['location'] ?? '',
      'address_line1': p['addressLine1'] ?? '',
      'area_street_village': p['areaStreetVillage'] ?? '',
      'landmark': p['landmark'] ?? '',
      'city': p['city'] ?? '',
      'state': p['state'] ?? '',
      'pincode': p['pincode'] ?? '',
      'country': p['country'] ?? 'India',
      if (p['latitude'] != null) 'latitude': p['latitude'],
      if (p['longitude'] != null) 'longitude': p['longitude'],
    });
    return res.success;
  }

  // ── LOCAL → SERVER (service listings) ───────
  // Full-replace sync: my listings are rebuilt to match the
  // You-page's primary + other services exactly.
  static Future<void> syncServices(Map<String, dynamic> p) async {
    final user = await SessionManager.getUser();
    final myId = int.tryParse('${user?['id']}');
    if (myId == null) return;

    String typeToUnit(dynamic t) =>
        (t ?? '').toString() == 'per hour' ? 'per_hour' : 'per_day';

    // delete existing listings
    final existing = await ServiceApi.getServices(providerId: myId);
    if (existing.success && existing.data is Map) {
      for (final s in (existing.data['services'] ?? [])) {
        final id = int.tryParse('${s['id']}');
        if (id != null) await ServiceApi.deleteService(id);
      }
    }

    final city = (p['city'] ?? '').toString().trim();
    Future<void> create(Map svc, bool primary) async {
      final name = (svc['name'] ?? '').toString().trim();
      final charge = (svc['charge'] ?? '').toString().trim();
      if (name.isEmpty || charge.isEmpty) return;
      await ServiceApi.createService({
        'category_id': _generalCategoryId,
        'title': name,
        'price': charge,
        'price_unit': typeToUnit(svc['type']),
        'is_primary': primary,
        'city': city.isEmpty ? 'India' : city,
      });
    }

    final primary = p['primaryService'];
    if (primary is Map) await create(primary, true);
    for (final o in (p['otherServices'] as List? ?? [])) {
      if (o is Map) await create(o, false);
    }
  }
}
