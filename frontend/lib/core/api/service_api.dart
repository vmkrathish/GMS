// Service + category + suggestion endpoints — /api/services
import '../config/api_endpoints.dart';
import '../services/api_service.dart';

class ServiceApi {
  /// Categories with emoji, fetched live from backend.
  static Future<ApiResult> getCategories() =>
      ApiService.get(ApiEndpoints.categories);

  /// Autocomplete suggestions for the search bar.
  static Future<ApiResult> getSuggestions(String q, {int limit = 10}) =>
      ApiService.get(ApiEndpoints.suggestions,
          query: {'q': q, 'limit': '$limit'});

  /// Record a search term — new terms get added to the shared
  /// suggestion list (self-growing taxonomy), existing terms
  /// bump popularity.
  static Future<ApiResult> recordSearchTerm(String term) =>
      ApiService.post(ApiEndpoints.suggestions, {'term': term});

  /// Service listings. Optional filters: city, category_id, q.
  static Future<ApiResult> getServices({
    String? city,
    int? categoryId,
    String? q,
    int? providerId,
  }) =>
      ApiService.get(ApiEndpoints.services, query: {
        if (city != null) 'city': city,
        if (categoryId != null) 'category_id': '$categoryId',
        if (q != null && q.isNotEmpty) 'q': q,
        if (providerId != null) 'provider_id': '$providerId',
      });

  static Future<ApiResult> getServiceById(int id) =>
      ApiService.get(ApiEndpoints.serviceById(id));

  /// Rapido-style radius-expanding discovery for the live map.
  /// Tries 5→10→20→50km, returns the tightest tier with any results.
  /// Pass [categoryId] for a known category, or [q] for free-text
  /// search (e.g. typed into the map's search bar) — the backend
  /// falls back to a fuzzy "similar services" match at 50km if the
  /// exact category has nobody nearby at all.
  /// Home page "Recommended for You" — ranked using either the
  /// logged-in user's saved Home location, or an explicit lat/lng
  /// override (used for the "Current location" toggle). Falls back
  /// gracefully (same as the existing default ordering) if no Home
  /// location is saved AND no override was given — callers don't
  /// need to handle that case specially, the response shape stays
  /// identical either way.
  static Future<ApiResult> getRecommendedServices({
    String? q,
    int? categoryId,
    int limit = 10,
    double? lat,
    double? lng,
    String sort = 'smart', // 'smart' = weighted, 'distance' = nearest-first (KNN-style)
  }) =>
      ApiService.get('/services/recommended', query: {
        if (q != null && q.isNotEmpty) 'q': q,
        if (categoryId != null) 'category_id': '$categoryId',
        if (lat != null) 'lat': '$lat',
        if (lng != null) 'lng': '$lng',
        'sort': sort,
        'limit': '$limit',
      });

  static Future<ApiResult> getNearbyServices({
    required double lat,
    required double lng,
    int? categoryId,
    String? q,
  }) =>
      ApiService.get('/services/nearby', query: {
        'lat': '$lat',
        'lng': '$lng',
        if (categoryId != null) 'category_id': '$categoryId',
        if (q != null && q.isNotEmpty) 'q': q,
      });

  // Provider-side (requires login):
  static Future<ApiResult> createService(Map<String, dynamic> body) =>
      ApiService.post(ApiEndpoints.services, body);

  static Future<ApiResult> updateService(int id, Map<String, dynamic> body) =>
      ApiService.put(ApiEndpoints.serviceById(id), body);

  static Future<ApiResult> deleteService(int id) =>
      ApiService.delete(ApiEndpoints.serviceById(id));
}
