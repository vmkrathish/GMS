// Reverse geocoding — mirrors /api/geo/reverse
//
// Always goes through our own backend (never the `geocoding` Flutter
// plugin directly) because that plugin has no Web implementation and
// silently fails on Flutter Web, which is what caused raw
// latitude/longitude to show up instead of a place name.
import '../services/api_service.dart';

class GeoApi {
  /// Returns a short human-readable place name, or null if the
  /// service couldn't resolve one. Callers should never fall back to
  /// printing raw coordinates when this returns null — show a plain
  /// "Location pinned" label instead.
  static Future<String?> reverseGeocode(double lat, double lng) async {
    final res = await ApiService.get('/geo/reverse', query: {
      'lat': '$lat',
      'lng': '$lng',
    });
    if (res.success && res.data is Map && res.data['address'] != null) {
      final addr = res.data['address'].toString().trim();
      return addr.isEmpty ? null : addr;
    }
    return null;
  }

  /// Full result including structured components (city, state,
  /// postal_code, country, street…) — used by Edit Profile to
  /// autofill individual address fields, not just one label line.
  /// Returns null on any failure.
  static Future<Map<String, dynamic>?> reverseGeocodeFull(
      double lat, double lng) async {
    final res = await ApiService.get('/geo/reverse', query: {
      'lat': '$lat',
      'lng': '$lng',
    });
    if (res.success && res.data is Map && res.data['success'] == true) {
      return Map<String, dynamic>.from(res.data);
    }
    return null;
  }

  /// Real driving distance/duration + route line between two points
  /// (Google-Maps-style "how far, how long"), via the backend's OSRM
  /// proxy. Returns null on any failure — callers should fall back to
  /// the straight-line distance_km they already have rather than
  /// show nothing.
  static Future<Map<String, dynamic>?> getDrivingRoute({
    required double fromLat,
    required double fromLng,
    required double toLat,
    required double toLng,
  }) async {
    final res = await ApiService.get('/geo/route', query: {
      'from_lat': '$fromLat',
      'from_lng': '$fromLng',
      'to_lat': '$toLat',
      'to_lng': '$toLng',
    });
    if (res.success && res.data is Map && res.data['success'] == true) {
      return Map<String, dynamic>.from(res.data);
    }
    return null;
  }

  /// Resolves a 6-digit Indian PIN code to city/district/state.
  /// Returns null on any failure — caller should leave the city field
  /// untouched rather than clear it when a lookup doesn't succeed.
  static Future<Map<String, dynamic>?> lookupPincode(String code) async {
    final res = await ApiService.get('/geo/pincode', query: {'code': code});
    if (res.success && res.data is Map && res.data['success'] == true) {
      return Map<String, dynamic>.from(res.data);
    }
    return null;
  }

  /// City-name autocomplete — as-you-type suggestions for the
  /// Town/City field, each with its district/state/pincode so
  /// selecting one can fill in more than just the city name.
  /// Optionally scoped to a state and/or district (once picked) so
  /// results are actually relevant, not matches from anywhere in
  /// the country. Returns an empty list (never null) on failure.
  static Future<List<Map<String, dynamic>>> suggestCities(String query,
      {String? state, String? district}) async {
    final res = await ApiService.get('/geo/city-suggestions', query: {
      'q': query,
      if (state != null && state.isNotEmpty) 'state': state,
      if (district != null && district.isNotEmpty) 'district': district,
    });
    if (res.success && res.data is Map && res.data['suggestions'] is List) {
      return (res.data['suggestions'] as List)
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
    }
    return [];
  }

  /// Districts available for a given state. Currently only Tamil
  /// Nadu has a hardcoded list (this app's primary use case);
  /// returns an empty list for other states rather than guessed
  /// data — caller should let District stay free-text in that case.
  static Future<List<String>> getDistrictsForState(String state) async {
    final res =
        await ApiService.get('/geo/districts', query: {'state': state});
    if (res.success && res.data is Map && res.data['districts'] is List) {
      return List<String>.from(res.data['districts']);
    }
    return [];
  }

  /// States available for a given country — instant for India (no
  /// network round-trip needed), looked up for anywhere else.
  /// Returns an empty list on failure, never null.
  static Future<List<String>> getStatesForCountry(String country) async {
    final res =
        await ApiService.get('/geo/states', query: {'country': country});
    if (res.success && res.data is Map && res.data['states'] is List) {
      return List<String>.from(res.data['states']);
    }
    return [];
  }
}
