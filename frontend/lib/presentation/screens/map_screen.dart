// ─────────────────────────────────────────────
// presentation/screens/map_screen.dart
//
// Rapido-style live provider discovery map.
//  1. Verifies device location services are actually ON before
//     doing anything else (not just permission — the GPS toggle).
//  2. Lets the user search anchor from either their live GPS
//     position or their saved home address (two FABs, bottom-right).
//  3. Google-Maps-style search bar pinned to the top.
//  4. Searches nearby providers with radius escalation
//     (5→10→20→50km, server-side — see /api/services/nearby),
//     rendering each as their category's emoji pinned at the
//     provider's location.
//  5. Tapping a marker opens their public profile first (name,
//     rating, bio, services) — booking only happens from there,
//     tapping a specific service, exactly like everywhere else in
//     the app (same shared booking sheet).
// ─────────────────────────────────────────────
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart' as ll;
import 'package:geolocator/geolocator.dart';

import '../../core/api/service_api.dart';
import '../../core/api/user_api.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/booking_sheet.dart';
import '../../core/services/refresh_bus.dart';
import '../../core/widgets/gms_header.dart';
import 'public_profile_screen.dart';
import 'route_to_provider_screen.dart';

enum _MapState { checkingGps, gpsOff, permissionDenied, ready }

enum _RefMode { current, home }

class MapScreen extends StatefulWidget {
  const MapScreen({super.key});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final MapController _mapController = MapController();
  final TextEditingController _searchCtrl = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;

  List<String> _suggestions = [];
  bool _showSuggestions = false;
  int _highlightedIndex = -1; // -1 = nothing highlighted yet

  _MapState _state = _MapState.checkingGps;
  _RefMode _refMode = _RefMode.current;

  ll.LatLng? _currentPos;
  ll.LatLng? _homePos;
  String _homeLabel = 'Home';

  List<Map<String, dynamic>> _suggestedCategories = [];

  List<Map<String, dynamic>> _results = [];
  bool _searching = false;
  String? _statusMessage;
  bool _statusIsWarning = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) {
        // Don't hide immediately — clicking a suggestion with the
        // mouse also unfocuses the field at nearly the same instant,
        // and hiding right away can remove the suggestion list
        // before its own onTap finishes firing (a classic Flutter
        // web race: focus-loss processing can beat the tap-up
        // event). This delay gives that tap time to complete; the
        // suggestion's own onTap already sets _showSuggestions=false
        // itself once selected, so this only matters for genuine
        // "clicked away" cases.
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted && !_searchFocus.hasFocus) {
            setState(() => _showSuggestions = false);
          }
        });
      }
    });
    RefreshBus.map.addListener(_onRefreshBusMap);
  }

  void _onRefreshBusMap() {
    if (!mounted) return;
    if (_searchCtrl.text.trim().isNotEmpty) {
      _search(_searchCtrl.text);
    } else {
      _loadDefaultNearby();
    }
  }

  @override
  void dispose() {
    RefreshBus.map.removeListener(_onRefreshBusMap);
    _debounce?.cancel();
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  ll.LatLng? get _activeCenter =>
      _refMode == _RefMode.current ? _currentPos : _homePos;

  // ── GPS verification + initial positioning ──────
  Future<void> _bootstrap() async {
    setState(() => _state = _MapState.checkingGps);

    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() => _state = _MapState.gpsOff);
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => _state = _MapState.permissionDenied);
      return;
    }

    try {
      final pos = await Geolocator.getCurrentPosition();
      _currentPos = ll.LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      // fall through — user can still switch to Home reference
    }

    // Load saved home location from profile (self-sufficient, same
    // pattern as the booking sheet — doesn't depend on the You tab
    // having been visited first).
    final res = await UserApi.getMe();
    if (res.success && res.data is Map) {
      final u = Map<String, dynamic>.from(res.data['user'] ?? {});
      final lat = double.tryParse('${u['latitude']}');
      final lng = double.tryParse('${u['longitude']}');
      if (lat != null && lng != null) {
        _homePos = ll.LatLng(lat, lng);
        _homeLabel = (u['location_text'] ?? 'Home').toString();
        if (_homeLabel.trim().isEmpty) _homeLabel = 'Home';
      }
    }

    if (!mounted) return;
    setState(() {
      _state = _MapState.ready;
      if (_currentPos == null && _homePos != null) _refMode = _RefMode.home;
    });
    // Default view: show everyone active within 50km right away —
    // an explicit search only narrows this further, it's never
    // required just to see who's nearby.
    _loadDefaultNearby();
  }

  Future<void> _loadDefaultNearby() async {
    final center = _activeCenter;
    if (center == null) return;
    setState(() {
      _searching = true;
      _statusMessage = null;
    });
    final res = await ServiceApi.getNearbyServices(
      lat: center.latitude,
      lng: center.longitude,
    );
    if (!mounted) return;
    if (!res.success || res.data is! Map) {
      setState(() => _searching = false);
      return;
    }
    final data = res.data as Map;
    final list = (data['services'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    setState(() {
      _searching = false;
      _results = list;
      _statusMessage = list.isEmpty
          ? 'No providers found within 50km yet.'
          : '${list.length} provider${list.length == 1 ? '' : 's'} nearby';
      _statusIsWarning = list.isEmpty;
    });
  }

  void _switchReference(_RefMode mode) {
    final target = mode == _RefMode.current ? _currentPos : _homePos;
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(mode == _RefMode.current
              ? 'Current location unavailable.'
              : 'No saved home location yet — set one in your profile.')));
      return;
    }
    setState(() => _refMode = mode);
    _mapController.move(target, 14);

    // Make it obvious the switch actually changed the search anchor —
    // both modes search up to the same 50km ceiling, just starting
    // from a different point.
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      duration: const Duration(seconds: 2),
      content: Text(mode == _RefMode.current
          ? 'Searching from your current location'
          : 'Searching from $_homeLabel'),
    ));

    // If a search was already run, repeat it from the new center so
    // the results visibly update — otherwise switching feels like it
    // does nothing until you search again manually.
    if (_searchCtrl.text.trim().isNotEmpty) {
      _search(_searchCtrl.text);
    } else {
      _loadDefaultNearby();
    }
  }

  // ── Live suggestions while typing (same pattern as Home) ──
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (value.trim().isEmpty) {
        setState(() {
          _suggestions = [];
          _showSuggestions = false;
          _highlightedIndex = -1;
        });
        _loadDefaultNearby();
        return;
      }
      final res = await ServiceApi.getSuggestions(value.trim());
      if (!mounted) return;
      List<String> items = [];
      if (res.success && res.data is Map && res.data['suggestions'] is List) {
        items = List<String>.from(res.data['suggestions']);
      }
      setState(() {
        _suggestions = items;
        _showSuggestions = items.isNotEmpty && _searchFocus.hasFocus;
        _highlightedIndex = -1;
      });
    });
  }

  /// Handles Down/Up arrow to move through suggestions, Enter to pick
  /// the highlighted one. Returns `handled` for keys we intercept so
  /// the TextField doesn't also move its text cursor at the same time.
  KeyEventResult _handleSearchKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (!_showSuggestions || _suggestions.isEmpty) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlightedIndex = (_highlightedIndex + 1) % _suggestions.length;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlightedIndex = _highlightedIndex <= 0
            ? _suggestions.length - 1
            : _highlightedIndex - 1;
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (_highlightedIndex >= 0 && _highlightedIndex < _suggestions.length) {
        final picked = _suggestions[_highlightedIndex];
        _searchCtrl.text = picked;
        setState(() {
          _showSuggestions = false;
          _highlightedIndex = -1;
        });
        _searchFocus.unfocus();
        _search(picked);
        return KeyEventResult.handled;
      }
      // Nothing highlighted yet — let the TextField's own onSubmitted
      // run the raw typed text, same as pressing the send button.
    }
    return KeyEventResult.ignored;
  }

  // ── Search with radius escalation ───────────────
  Future<void> _search(String term) async {
    final t = term.trim();
    if (t.isEmpty) return;
    final center = _activeCenter;
    if (center == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('No location available to search from yet.')));
      return;
    }

    setState(() {
      _searching = true;
      _statusMessage = null;
    });

    final res = await ServiceApi.getNearbyServices(
      lat: center.latitude,
      lng: center.longitude,
      q: t,
    );

    if (!mounted) return;

    if (!res.success || res.data is! Map) {
      setState(() {
        _searching = false;
        _statusMessage = res.isOffline
            ? 'Unable to connect. Please check your connection and try again.'
            : res.message;
        _statusIsWarning = true;
        _results = [];
      });
      return;
    }

    final data = res.data as Map;
    final list = (data['services'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final radius = data['radius_used_km'];
    final isSimilar = data['is_similar'] == true;
    final suggestedCats = (data['suggested_categories'] as List? ?? [])
        .map((e) => Map<String, dynamic>.from(e))
        .toList();

    setState(() {
      _searching = false;
      _results = list;
      _suggestedCategories = [];
      if (list.isEmpty) {
        _statusMessage = (data['message'] ?? 'No providers found nearby.')
            .toString();
        _statusIsWarning = true;
        _suggestedCategories = suggestedCats;
      } else if (isSimilar) {
        _statusMessage =
            'No exact match nearby — showing similar services within ${radius}km';
        _statusIsWarning = true;
      } else {
        _statusMessage =
            '${list.length} provider${list.length == 1 ? '' : 's'} found within ${radius}km';
        _statusIsWarning = false;
      }
    });

    if (list.isNotEmpty) {
      final first = list.first;
      final lat = double.tryParse('${first['provider_lat']}');
      final lng = double.tryParse('${first['provider_lng']}');
      if (lat != null && lng != null) {
        _mapController.move(ll.LatLng(lat, lng), 12);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GMSHeader(parentContext: context), // showMenu defaults to false
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    switch (_state) {
      case _MapState.checkingGps:
        return const Center(child: CircularProgressIndicator());

      case _MapState.gpsOff:
        return _messageScreen(
          icon: Icons.location_off,
          title: 'Location services are off',
          body:
              'Turn on GPS/location services on your device to find services near you.',
          actionLabel: 'Open Location Settings',
          onAction: () async {
            await Geolocator.openLocationSettings();
            _bootstrap();
          },
        );

      case _MapState.permissionDenied:
        return _messageScreen(
          icon: Icons.location_disabled,
          title: 'Location permission needed',
          body:
              'GMS needs your location to show nearby service providers on the map.',
          actionLabel: 'Grant Permission',
          onAction: _bootstrap,
        );

      case _MapState.ready:
        return _mapBody();
    }
  }

  Widget _messageScreen({
    required IconData icon,
    required String title,
    required String body,
    required String actionLabel,
    required VoidCallback onAction,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 64, color: Colors.black26),
            const SizedBox(height: 16),
            Text(title,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(body,
                style: const TextStyle(color: Colors.black54),
                textAlign: TextAlign.center),
            const SizedBox(height: 20),
            ElevatedButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }

  Widget _mapBody() {
    final center = _activeCenter ?? const ll.LatLng(11.0168, 76.9558);

    final markers = <Marker>[
      if (_currentPos != null)
        Marker(
          point: _currentPos!,
          width: 24,
          height: 24,
          child: Container(
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
            ),
          ),
        ),
      if (_homePos != null)
        Marker(
          point: _homePos!,
          width: 34,
          height: 34,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.green.shade600,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.25),
                    blurRadius: 4,
                    offset: const Offset(0, 2)),
              ],
            ),
            child: const Icon(Icons.home_rounded,
                color: Colors.white, size: 16),
          ),
        ),
      for (final s in _results)
        if (double.tryParse('${s['provider_lat']}') != null &&
            double.tryParse('${s['provider_lng']}') != null)
          Marker(
            point: ll.LatLng(
              double.parse('${s['provider_lat']}'),
              double.parse('${s['provider_lng']}'),
            ),
            width: 44,
            height: 44,
            child: GestureDetector(
              onTap: () => _openRouteToProvider(s),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.25),
                        blurRadius: 4,
                        offset: const Offset(0, 2)),
                  ],
                  border: Border.all(color: AppTheme.primaryBlue, width: 2),
                ),
                alignment: Alignment.center,
                child: Text(
                  (s['category_emoji'] ?? '🛠️').toString(),
                  style: const TextStyle(fontSize: 20),
                ),
              ),
            ),
          ),
    ];

    return Stack(
      children: [
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(initialCenter: center, initialZoom: 13),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'com.example.gms',
            ),
            MarkerLayer(markers: markers),
          ],
        ),

        // Google-Maps-style search bar, pinned to the top.
        Positioned(
          top: 12,
          left: 12,
          right: 12,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(28),
                color: Colors.white,
                child: Focus(
                  onKeyEvent: _handleSearchKeyEvent,
                  child: TextField(
                  controller: _searchCtrl,
                  focusNode: _searchFocus,
                  textInputAction: TextInputAction.search,
                  onChanged: _onSearchChanged,
                  onSubmitted: (v) {
                    setState(() => _showSuggestions = false);
                    _searchFocus.unfocus();
                    _search(v);
                  },
                  decoration: InputDecoration(
                    hintText: 'Search a service — e.g. Electrician',
                    prefixIcon: const Icon(Icons.search,
                        color: AppTheme.primaryBlue),
                    suffixIcon: _searching
                        ? const Padding(
                            padding: EdgeInsets.all(12),
                            child: SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2)))
                        : IconButton(
                            icon: const Icon(Icons.send_rounded,
                                color: AppTheme.primaryBlue),
                            onPressed: () => _search(_searchCtrl.text),
                          ),
                    filled: true,
                    fillColor: Colors.white,
                    contentPadding:
                        const EdgeInsets.symmetric(vertical: 14),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(28),
                        borderSide: BorderSide.none),
                  ),
                  ),
                ),
              ),
              if (_showSuggestions)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  constraints: const BoxConstraints(maxHeight: 240),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.12),
                          blurRadius: 12,
                          offset: const Offset(0, 4)),
                    ],
                  ),
                  child: ListView.separated(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: Colors.grey.shade100),
                    itemBuilder: (_, i) {
                      final selected = i == _highlightedIndex;
                      return ListTile(
                      dense: true,
                      tileColor:
                          selected ? Colors.blue.shade50 : Colors.transparent,
                      leading: Icon(Icons.search,
                          size: 18,
                          color: selected
                              ? AppTheme.primaryBlue
                              : Colors.black45),
                      title: Text(_suggestions[i],
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                      onTap: () {
                        _searchCtrl.text = _suggestions[i];
                        setState(() => _showSuggestions = false);
                        _searchFocus.unfocus();
                        _search(_suggestions[i]);
                      },
                      );
                    },
                  ),
                ),
              if (_statusMessage != null)
                Container(
                  margin: const EdgeInsets.only(top: 8),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _statusIsWarning
                        ? Colors.amber.shade50
                        : Colors.green.shade50,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.08),
                          blurRadius: 6,
                          offset: const Offset(0, 2)),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _statusMessage!,
                        style: TextStyle(
                            fontSize: 12.5,
                            color: _statusIsWarning
                                ? Colors.amber.shade900
                                : Colors.green.shade800),
                      ),
                      if (_suggestedCategories.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final cat in _suggestedCategories)
                              ActionChip(
                                backgroundColor: Colors.white,
                                side: BorderSide(color: Colors.amber.shade200),
                                avatar: Text(
                                    (cat['emoji'] ?? '🛠️').toString(),
                                    style: const TextStyle(fontSize: 13)),
                                label: Text(cat['name'].toString(),
                                    style: const TextStyle(fontSize: 11.5)),
                                onPressed: () {
                                  _searchCtrl.text = cat['name'].toString();
                                  _search(cat['name'].toString());
                                },
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
            ],
          ),
        ),

        // Reference-location toggle, bottom-right.
        Positioned(
          right: 16,
          bottom: 24,
          child: Column(
            children: [
              _refFab(
                icon: Icons.my_location,
                label: 'Current',
                active: _refMode == _RefMode.current,
                onTap: () => _switchReference(_RefMode.current),
              ),
              const SizedBox(height: 10),
              _refFab(
                icon: Icons.home_rounded,
                label: _homeLabel.length > 10
                    ? '${_homeLabel.substring(0, 10)}…'
                    : _homeLabel,
                active: _refMode == _RefMode.home,
                onTap: () => _switchReference(_RefMode.home),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _refFab({
    required IconData icon,
    required String label,
    required bool active,
    required VoidCallback onTap,
  }) {
    return Column(
      children: [
        FloatingActionButton(
          heroTag: label,
          mini: true,
          backgroundColor: active ? AppTheme.primaryBlue : Colors.white,
          foregroundColor: active ? Colors.white : AppTheme.primaryBlue,
          onPressed: onTap,
          child: Icon(icon),
        ),
        const SizedBox(height: 2),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                  color: Colors.black.withOpacity(0.1), blurRadius: 3),
            ],
          ),
          child: Text(label,
              style: const TextStyle(fontSize: 9.5, color: Colors.black87)),
        ),
      ],
    );
  }

  // Small preview before committing to the full profile — shows just
  // enough (name, rating, distance) so tapping the marker doesn't
  // feel like a jump straight into someone's whole profile blind.
  //
  // Tapping a pin now goes straight to the Google-Maps-style distance
  // view first — the profile/booking step only happens after that.
  void _openRouteToProvider(Map<String, dynamic> s) {
    final providerId = int.tryParse('${s['provider_id']}');
    final lat = double.tryParse('${s['provider_lat']}');
    final lng = double.tryParse('${s['provider_lng']}');
    if (providerId == null || lat == null || lng == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RouteToProviderScreen(
        providerId: providerId,
        providerName: (s['provider_name'] ?? 'Provider').toString(),
        providerLat: lat,
        providerLng: lng,
        providerAvatar: s['provider_avatar']?.toString(),
        bookingService: s,
      ),
    ));
  }

  void _openProviderPreview(Map<String, dynamic> s) {
    final name = (s['provider_name'] ?? 'Provider').toString();
    final rating = double.tryParse('${s['average_rating'] ?? 0}') ?? 0;
    final reviews = s['review_count'] ?? 0;
    final distance = double.tryParse('${s['distance_km'] ?? 0}') ?? 0;
    final title = (s['title'] ?? '').toString();
    final providerId = int.tryParse('${s['provider_id']}');

    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name,
                style:
                    const TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            Text(title, style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 8),
            Row(
              children: [
                ...List.generate(
                  5,
                  (i) => Icon(
                      i < rating.round() ? Icons.star : Icons.star_border,
                      color: Colors.amber,
                      size: 16),
                ),
                const SizedBox(width: 6),
                Text('($reviews)',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
                const Spacer(),
                Text('${distance.toStringAsFixed(1)} km away',
                    style: const TextStyle(fontSize: 12, color: Colors.black54)),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: providerId == null
                        ? null
                        : () {
                            Navigator.of(ctx).pop();
                            Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) => PublicProfileScreen(
                                    userId: providerId,
                                    fallbackName: name,
                                    fallbackAvatar:
                                        s['provider_avatar']?.toString())));
                          },
                    child: const Text('View Profile'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    // Same action as tapping a provider card on Home —
                    // straight into the shared booking sheet for this
                    // exact service.
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      openBookingSheet(context, s);
                    },
                    child: const Text('Book Now'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
