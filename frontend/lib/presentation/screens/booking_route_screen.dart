// ─────────────────────────────────────────────
// presentation/screens/booking_route_screen.dart
//
// Route view for a SPECIFIC booking. Unlike RouteToProviderScreen
// (free Home/Current toggle while browsing), both endpoints here are
// fixed by the booking's own context — the caller decides what they
// are and passes them straight in:
//
//   My Bookings (I'm the customer): the provider is coming to ME.
//   origin = provider's registered location (fixed), destination =
//   MY location AS SAVED ON THIS BOOKING when I made it — never a
//   live re-fetch, since I may have moved since then.
//
//   Received (I'm the provider): I'm going to THEM. origin = MY live
//   current location (fetched fresh here, since I'm heading there
//   today), destination = the customer's location as saved on this
//   booking.
//
// Distinct, non-pin-emoji markers for start vs end (🚗 them/origin,
// 🙂 you/destination by default — caller can override).
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:geolocator/geolocator.dart';

import '../../core/api/geo_api.dart';
import '../../core/theme/app_theme.dart';

class BookingRouteScreen extends StatefulWidget {
  final String title;

  /// If null, this endpoint means "fetch my live current location" —
  /// used for the Received/provider-going-there case. Otherwise it's
  /// a fixed point already known (a booking's saved coordinates).
  final double? originLat;
  final double? originLng;
  final bool originIsLiveMe;
  final String originLabel;
  final String originEmoji;

  final double? destLat;
  final double? destLng;
  final String destLabel;
  final String destEmoji;

  const BookingRouteScreen({
    super.key,
    required this.title,
    this.originLat,
    this.originLng,
    this.originIsLiveMe = false,
    required this.originLabel,
    this.originEmoji = '🚗',
    required this.destLat,
    required this.destLng,
    required this.destLabel,
    this.destEmoji = '🙂',
  });

  @override
  State<BookingRouteScreen> createState() => _BookingRouteScreenState();
}

class _BookingRouteScreenState extends State<BookingRouteScreen> {
  final MapController _mapController = MapController();

  ll.LatLng? _origin;
  ll.LatLng? _dest;
  bool _loadingMyLocation = false;
  bool _myLocationUnavailable = false;

  Map<String, dynamic>? _route;
  bool _loadingRoute = false;
  bool _routeUnavailable = false;

  @override
  void initState() {
    super.initState();
    if (widget.destLat != null && widget.destLng != null) {
      _dest = ll.LatLng(widget.destLat!, widget.destLng!);
    }
    if (widget.originIsLiveMe) {
      _fetchMyCurrentLocation();
    } else if (widget.originLat != null && widget.originLng != null) {
      _origin = ll.LatLng(widget.originLat!, widget.originLng!);
      _fetchRoute();
    }
  }

  Future<void> _fetchMyCurrentLocation() async {
    setState(() => _loadingMyLocation = true);
    try {
      final enabled = await Geolocator.isLocationServiceEnabled();
      if (enabled) {
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (perm == LocationPermission.always ||
            perm == LocationPermission.whileInUse) {
          final pos = await Geolocator.getCurrentPosition();
          _origin = ll.LatLng(pos.latitude, pos.longitude);
        }
      }
    } catch (_) {
      // leave _origin null
    }
    if (!mounted) return;
    setState(() {
      _loadingMyLocation = false;
      _myLocationUnavailable = _origin == null;
    });
    if (_origin != null) _fetchRoute();
  }

  Future<void> _fetchRoute() async {
    if (_origin == null || _dest == null) return;
    setState(() {
      _loadingRoute = true;
      _routeUnavailable = false;
    });
    final result = await GeoApi.getDrivingRoute(
      fromLat: _origin!.latitude,
      fromLng: _origin!.longitude,
      toLat: _dest!.latitude,
      toLng: _dest!.longitude,
    );
    if (!mounted) return;
    setState(() {
      _route = result;
      _loadingRoute = false;
      _routeUnavailable = result == null;
    });
    if (result != null) {
      final bounds = LatLngBounds.fromPoints([_origin!, _dest!]);
      _mapController.fitCamera(
          CameraFit.bounds(bounds: bounds, padding: const EdgeInsets.all(60)));
    }
  }

  double _straightLineKm() {
    if (_origin == null || _dest == null) return 0;
    return const ll.Distance().as(ll.LengthUnit.Kilometer, _origin!, _dest!);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(
        children: [
          Expanded(
            child: _loadingMyLocation
                ? const Center(child: CircularProgressIndicator())
                : _myLocationUnavailable
                    ? _unavailableState()
                    : _mapView(),
          ),
          if (!_loadingMyLocation && !_myLocationUnavailable) _infoPanel(),
        ],
      ),
    );
  }

  Widget _unavailableState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.location_off, size: 56, color: Colors.black26),
            const SizedBox(height: 16),
            const Text('Could not get your current location',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
                'Turn on location services and grant permission to see the route.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54)),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: _fetchMyCurrentLocation,
              child: const Text('Try Again'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mapView() {
    final center = _origin ?? _dest ?? const ll.LatLng(11.0168, 76.9558);
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(initialCenter: center, initialZoom: 12),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.example.gms',
        ),
        if (_route != null && _route!['polyline'] != null)
          PolylineLayer(polylines: [
            Polyline(
              points: (_route!['polyline'] as List)
                  .map((p) => ll.LatLng(
                      (p[0] as num).toDouble(), (p[1] as num).toDouble()))
                  .toList(),
              strokeWidth: 4,
              color: AppTheme.primaryBlue,
            ),
          ]),
        MarkerLayer(markers: [
          if (_origin != null)
            Marker(
              point: _origin!,
              width: 46,
              height: 46,
              child: _labeledMarker(widget.originEmoji),
            ),
          if (_dest != null)
            Marker(
              point: _dest!,
              width: 46,
              height: 46,
              child: _labeledMarker(widget.destEmoji),
            ),
        ]),
      ],
    );
  }

  Widget _labeledMarker(String emoji) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.primaryBlue, width: 2),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.25),
              blurRadius: 4,
              offset: const Offset(0, 2)),
        ],
      ),
      alignment: Alignment.center,
      child: Text(emoji, style: const TextStyle(fontSize: 22)),
    );
  }

  Widget _infoPanel() {
    final hasRoute = _route != null;
    final distanceKm =
        hasRoute ? (_route!['distance_km'] as num).toDouble() : _straightLineKm();
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
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(widget.originEmoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(widget.originLabel,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5))),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(left: 7),
            child: SizedBox(
                height: 14,
                child: VerticalDivider(width: 2, color: Colors.black26)),
          ),
          Row(
            children: [
              Text(widget.destEmoji, style: const TextStyle(fontSize: 16)),
              const SizedBox(width: 6),
              Expanded(
                  child: Text(widget.destLabel,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5))),
            ],
          ),
          const SizedBox(height: 12),
          if (_loadingRoute)
            const Row(
              children: [
                SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 10),
                Text('Calculating route…'),
              ],
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
                      if (_routeUnavailable)
                        const Text(
                          'Straight-line distance (driving route unavailable right now)',
                          style: TextStyle(fontSize: 11, color: Colors.black54),
                        ),
                    ],
                  ),
                ),
              ],
            ),
        ],
      ),
    );
  }
}
