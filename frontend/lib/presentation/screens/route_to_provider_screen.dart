// ─────────────────────────────────────────────
// presentation/screens/route_to_provider_screen.dart
//
// Google-Maps-style "how far, how long" view — shown BEFORE viewing
// a provider's profile or booking them, whether reached by tapping a
// location on a booking card or tapping a pin on the live map.
//
// Shows real driving distance + estimated time (via the backend's
// OSRM proxy) and the actual route line on a small map, with a
// Home/Current toggle for the reference point (defaults to Home).
// Falls back to the straight-line distance if the routing service is
// unreachable, rather than showing nothing.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:geolocator/geolocator.dart';

import '../../core/api/geo_api.dart';
import '../../core/api/user_api.dart';
import '../../core/theme/app_theme.dart';
import 'public_profile_screen.dart';

class RouteToProviderScreen extends StatefulWidget {
  final int providerId;
  final String providerName;
  final double providerLat;
  final double providerLng;
  final String? providerAvatar;
  /// If set, "Continue" opens the booking sheet for this exact
  /// service instead of the profile page.
  final Map<String, dynamic>? bookingService;

  const RouteToProviderScreen({
    super.key,
    required this.providerId,
    required this.providerName,
    required this.providerLat,
    required this.providerLng,
    this.providerAvatar,
    this.bookingService,
  });

  @override
  State<RouteToProviderScreen> createState() => _RouteToProviderScreenState();
}

class _RouteToProviderScreenState extends State<RouteToProviderScreen> {
  final MapController _mapController = MapController();

  String _refMode = 'home'; // 'home' | 'current'
  ll.LatLng? _homePos;
  ll.LatLng? _currentPos;
  bool _loadingLocation = true;

  Map<String, dynamic>? _route; // from OSRM: distance_km, duration_min, polyline
  bool _loadingRoute = false;
  bool _routeUnavailable = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  ll.LatLng? get _activeOrigin =>
      _refMode == 'home' ? _homePos : _currentPos;

  Future<void> _bootstrap() async {
    final res = await UserApi.getMe();
    if (res.success && res.data is Map) {
      final u = Map<String, dynamic>.from(res.data['user'] ?? {});
      final lat = double.tryParse('${u['latitude']}');
      final lng = double.tryParse('${u['longitude']}');
      if (lat != null && lng != null) _homePos = ll.LatLng(lat, lng);
    }
    if (!mounted) return;
    setState(() => _loadingLocation = false);
    if (_homePos != null) {
      _fetchRoute();
    } else {
      // No saved Home location — fall back to Current automatically.
      await _switchRef('current');
    }
  }

  Future<void> _switchRef(String mode) async {
    if (mode == 'current' && _currentPos == null) {
      final pos = await _getCurrentPositionSafely();
      if (pos != null) _currentPos = ll.LatLng(pos.latitude, pos.longitude);
    }
    if (!mounted) return;
    setState(() => _refMode = mode);
    if (_activeOrigin != null) _fetchRoute();
  }

  Future<Position?> _getCurrentPositionSafely() async {
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (!enabled) return null;
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<void> _fetchRoute() async {
    final origin = _activeOrigin;
    if (origin == null) return;
    setState(() {
      _loadingRoute = true;
      _routeUnavailable = false;
    });
    final result = await GeoApi.getDrivingRoute(
      fromLat: origin.latitude,
      fromLng: origin.longitude,
      toLat: widget.providerLat,
      toLng: widget.providerLng,
    );
    if (!mounted) return;
    setState(() {
      _route = result;
      _loadingRoute = false;
      _routeUnavailable = result == null;
    });
    if (result != null) {
      // Fit the map to show both points.
      final bounds = LatLngBounds.fromPoints([
        origin,
        ll.LatLng(widget.providerLat, widget.providerLng),
      ]);
      _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)));
    }
  }

  double _straightLineKm() {
    final origin = _activeOrigin;
    if (origin == null) return 0;
    return const ll.Distance().as(
        ll.LengthUnit.Kilometer,
        origin,
        ll.LatLng(widget.providerLat, widget.providerLng));
  }

  void _continue() {
    if (widget.bookingService != null) {
      // Booking flow needs the shared booking sheet, which is only
      // reachable with a BuildContext still mounted on the Home/Map
      // navigator — simplest correct path is via the profile page's
      // own service tap, so route there with the service preselected.
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PublicProfileScreen(
          userId: widget.providerId,
          fallbackName: widget.providerName,
          fallbackAvatar: widget.providerAvatar,
        ),
      ));
    } else {
      Navigator.of(context).pushReplacement(MaterialPageRoute(
        builder: (_) => PublicProfileScreen(
          userId: widget.providerId,
          fallbackName: widget.providerName,
          fallbackAvatar: widget.providerAvatar,
        ),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final origin = _activeOrigin;
    final providerPoint = ll.LatLng(widget.providerLat, widget.providerLng);

    return Scaffold(
      appBar: AppBar(title: Text('Route to ${widget.providerName}')),
      body: Column(
        children: [
          Expanded(
            child: _loadingLocation
                ? const Center(child: CircularProgressIndicator())
                : Stack(
                    children: [
                      FlutterMap(
                        mapController: _mapController,
                        options: MapOptions(
                          initialCenter: origin ?? providerPoint,
                          initialZoom: 12,
                        ),
                        children: [
                          TileLayer(
                            urlTemplate:
                                'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                            userAgentPackageName: 'com.example.gms',
                          ),
                          if (_route != null && _route!['polyline'] != null)
                            PolylineLayer(polylines: [
                              Polyline(
                                points: (_route!['polyline'] as List)
                                    .map((p) => ll.LatLng(
                                        (p[0] as num).toDouble(),
                                        (p[1] as num).toDouble()))
                                    .toList(),
                                strokeWidth: 4,
                                color: AppTheme.primaryBlue,
                              ),
                            ]),
                          MarkerLayer(markers: [
                            if (origin != null)
                              Marker(
                                point: origin,
                                width: 42,
                                height: 42,
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: _refMode == 'home'
                                            ? Colors.green.shade600
                                            : AppTheme.primaryBlue,
                                        width: 3),
                                    boxShadow: [
                                      BoxShadow(
                                          color: Colors.black
                                              .withOpacity(0.25),
                                          blurRadius: 4,
                                          offset: const Offset(0, 2)),
                                    ],
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                      _refMode == 'home' ? '🏠' : '🧍',
                                      style: const TextStyle(fontSize: 18)),
                                ),
                              ),
                            Marker(
                              point: providerPoint,
                              width: 42,
                              height: 42,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                      color: Colors.orange.shade600,
                                      width: 3),
                                  boxShadow: [
                                    BoxShadow(
                                        color: Colors.black.withOpacity(0.25),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2)),
                                  ],
                                ),
                                alignment: Alignment.center,
                                child: const Text('🧑‍🔧',
                                    style: TextStyle(fontSize: 18)),
                              ),
                            ),
                          ]),
                        ],
                      ),
                      Positioned(
                        top: 12,
                        left: 12,
                        right: 12,
                        child: Row(
                          children: [
                            _refChip('home', Icons.home_rounded, 'Home'),
                            const SizedBox(width: 8),
                            _refChip(
                                'current', Icons.my_location, 'Current'),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          _routeInfoPanel(),
        ],
      ),
    );
  }

  Widget _refChip(String mode, IconData icon, String label) {
    final active = _refMode == mode;
    return Material(
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      color: active ? AppTheme.primaryBlue : Colors.white,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _switchRef(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 15, color: active ? Colors.white : Colors.black54),
              const SizedBox(width: 5),
              Text(label,
                  style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : Colors.black87)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _routeInfoPanel() {
    final hasRoute = _route != null;
    final distanceKm = hasRoute
        ? (_route!['distance_km'] as num).toDouble()
        : _straightLineKm();
    final durationMin =
        hasRoute ? (_route!['duration_min'] as num).toInt() : null;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 10,
              offset: const Offset(0, -3)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_loadingRoute)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                  SizedBox(width: 10),
                  Text('Calculating route…'),
                ],
              ),
            )
          else
            Row(
              children: [
                const Icon(Icons.directions_car,
                    color: AppTheme.primaryBlue, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${distanceKm.toStringAsFixed(1)} km'
                        '${durationMin != null ? ' • ~$durationMin min drive' : ''}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Text(
                        _routeUnavailable
                            ? 'Straight-line distance (driving route unavailable right now)'
                            : 'Driving distance & time from your ${_refMode == 'home' ? 'Home' : 'Current'} location',
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.black54),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _continue,
              style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 14)),
              child: const Text('Continue'),
            ),
          ),
        ],
      ),
    );
  }
}
