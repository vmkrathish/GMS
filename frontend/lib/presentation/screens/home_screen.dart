import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show rootBundle, LogicalKeyboardKey, KeyEvent, KeyDownEvent;
import 'package:geolocator/geolocator.dart';

import '../../core/api/service_api.dart';
import '../../core/services/api_service.dart' show ApiResult;
import '../../core/services/refresh_bus.dart';
import '../../core/data/default_categories.dart';
import '../../core/widgets/booking_sheet.dart';
import '../../core/widgets/user_avatar.dart';
import '../../core/widgets/gms_header.dart';
import '../../core/theme/app_theme.dart';
import 'public_profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocus = FocusNode();
  Timer? _debounce;

  String _searchQuery = '';
  List<String> _suggestions = [];
  bool _showSuggestions = false;
  int _highlightedIndex = -1;

  // "Recommended for You" location reference: 'home' (saved profile
  // location) or 'current' (live GPS) — both sort nearest-to-farthest,
  // capped at 50km, same as the Map screen's toggle.
  String _recRefMode = 'home';
  bool _recLoadingLocation = false;

  List<dynamic> categories = [];
  List<dynamic> recommendations = [];
  int? _selectedCategoryId;

  bool isLoadingCategories = true;
  bool isLoadingRecommendations = true;
  bool _liveData = false; // true once the API answered

  @override
  void initState() {
    super.initState();
    _fetchCategories();
    _fetchRecommendations();
    _searchFocus.addListener(() {
      if (!_searchFocus.hasFocus) {
        // Same fix as Map screen's search — delay the hide so a
        // mouse click on a suggestion (which also unfocuses the
        // field at nearly the same instant) has time to complete its
        // own onTap before the list disappears out from under it.
        Future.delayed(const Duration(milliseconds: 150), () {
          if (mounted && !_searchFocus.hasFocus) {
            setState(() => _showSuggestions = false);
          }
        });
      }
    });
    RefreshBus.home.addListener(_onRefreshBusHome);
  }

  void _onRefreshBusHome() {
    if (!mounted) return;
    _fetchCategories();
    _fetchRecommendations(
      q: _searchQuery.isNotEmpty ? _searchQuery : null,
      categoryId: _selectedCategoryId,
    );
  }

  @override
  void dispose() {
    RefreshBus.home.removeListener(_onRefreshBusHome);
    _debounce?.cancel();
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  // ── DATA ─────────────────────────────────────

  Future<void> _fetchCategories() async {
    final res = await ServiceApi.getCategories();
    if (!mounted) return;
    if (res.success && res.data is Map && res.data['categories'] is List) {
      setState(() {
        categories = res.data['categories'];
        _liveData = true;
        isLoadingCategories = false;
      });
    } else {
      // Offline / DB not connected yet → bundled taxonomy
      setState(() {
        categories = DefaultCategories.list;
        isLoadingCategories = false;
      });
    }
  }

  Future<void> _fetchRecommendations({String? q, int? categoryId}) async {
    setState(() => isLoadingRecommendations = true);

    // Default "Recommended for You" (no active search, no category
    // filter) uses the location-aware, nearest-to-farthest ranking —
    // from either the saved Home location or live Current GPS,
    // depending on the toggle. Active search/category browsing is
    // untouched — same endpoint, same behavior as before.
    ApiResult res;
    if (q == null && categoryId == null) {
      double? lat, lng;
      if (_recRefMode == 'current') {
        final pos = await _getCurrentPositionSafely();
        if (pos == null) {
          // Permission denied / GPS off — fall back to Home location
          // rather than showing an empty screen.
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                content: Text(
                    'Could not get current location — showing Home location instead.')));
          }
        } else {
          lat = pos.latitude;
          lng = pos.longitude;
        }
      }
      res = await ServiceApi.getRecommendedServices(
          lat: lat, lng: lng, sort: 'distance');
    } else {
      res = await ServiceApi.getServices(q: q, categoryId: categoryId);
    }
    if (!mounted) return;

    List<dynamic> list = [];
    if (res.success) {
      final d = res.data;
      if (d is List) list = d;
      if (d is Map && d['services'] is List) list = d['services'];
    }
    setState(() {
      recommendations = list;
      isLoadingRecommendations = false;
    });
  }

  /// GPS fetch with permission handling, used only by the Current-
  /// location recommendation toggle. Returns null on any failure so
  /// the caller can gracefully fall back rather than crash/hang.
  Future<Position?> _getCurrentPositionSafely() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition();
    } catch (_) {
      return null;
    }
  }

  Future<void> _setRecRefMode(String mode) async {
    if (_recRefMode == mode) return;
    setState(() {
      _recRefMode = mode;
      _recLoadingLocation = true;
    });
    await _fetchRecommendations();
    if (mounted) setState(() => _recLoadingLocation = false);
  }

  void _onSearchChanged(String value) {
    setState(() {
      _searchQuery = value.toLowerCase();
      _selectedCategoryId = null;
    });
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      if (value.trim().isEmpty) {
        setState(() {
          _suggestions = [];
          _showSuggestions = false;
          _highlightedIndex = -1;
        });
        // Cleared the box — go back to the default recommendations
        // rather than leaving stale search results on screen.
        _fetchRecommendations();
        return;
      }

      // Fetch live suggestions AND the actual results in parallel —
      // previously only the header text updated as you typed while
      // the results list stayed stale until an explicit submit,
      // which looked like "searching by name doesn't show anything"
      // even though the backend search itself worked correctly.
      final suggestionsFuture = ServiceApi.getSuggestions(value.trim());
      final resultsFuture = _fetchRecommendations(q: value.trim());

      final res = await suggestionsFuture;
      await resultsFuture;
      if (!mounted) return;
      List<String> items = [];
      if (res.success && res.data is Map && res.data['suggestions'] is List) {
        items = List<String>.from(res.data['suggestions']);
      } else {
        // Offline fallback autocomplete
        items = DefaultCategories.searchTerms
            .where((t) => t.contains(value.toLowerCase()))
            .take(8)
            .toList();
      }
      setState(() {
        _suggestions = items;
        _showSuggestions = items.isNotEmpty && _searchFocus.hasFocus;
        _highlightedIndex = -1;
      });
    });
  }

  /// Down/Up arrow moves through suggestions, Enter picks the
  /// highlighted one — same pattern as the Map screen's search.
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
        _submitSearch(_suggestions[_highlightedIndex]);
        setState(() => _highlightedIndex = -1);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _submitSearch(String term) {
    final t = term.trim();
    if (t.isEmpty) return;
    _searchController.text = t;
    setState(() {
      _searchQuery = t.toLowerCase();
      _showSuggestions = false;
      _selectedCategoryId = null;
    });
    _searchFocus.unfocus();
    // Record the term server-side: new terms join the shared
    // suggestion list; existing ones gain popularity.
    ServiceApi.recordSearchTerm(t);
    _fetchRecommendations(q: t);
  }

  void _onCategoryTap(Map<String, dynamic> cat) {
    final id = cat['id'] is int ? cat['id'] as int : int.tryParse('${cat['id']}');
    setState(() {
      _selectedCategoryId = _selectedCategoryId == id ? null : id;
      _searchController.clear();
      _searchQuery = '';
    });
    _fetchRecommendations(categoryId: _selectedCategoryId);
  }

  // ── UI ───────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      color: AppTheme.primaryBlue,
      onRefresh: () async {
        await _fetchCategories();
        await _fetchRecommendations(
            q: _searchQuery.isEmpty ? null : _searchQuery,
            categoryId: _selectedCategoryId);
      },
      child: ListView(
        padding: EdgeInsets.zero,
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _headerBar(context),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _searchBarWithSuggestions(),
                const SizedBox(height: 16),
                _adBanner(),
                const SizedBox(height: 20),
                _categorySection(),
                const SizedBox(height: 20),
                _recommendations(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _headerBar(BuildContext context) {
    return GMSHeader(parentContext: context, showMenu: true);
  }

  Widget _searchBarWithSuggestions() {
    return Column(
      children: [
        Material(
          elevation: 2,
          shadowColor: Colors.black12,
          borderRadius: BorderRadius.circular(26),
          child: Focus(
            onKeyEvent: _handleSearchKeyEvent,
            child: TextField(
            controller: _searchController,
            focusNode: _searchFocus,
            textInputAction: TextInputAction.search,
            onChanged: _onSearchChanged,
            onSubmitted: _submitSearch,
            decoration: InputDecoration(
              hintText: 'Search any service — plumber, tutor, editor…',
              hintStyle: const TextStyle(fontSize: 14),
              prefixIcon: const Icon(Icons.search, color: AppTheme.primaryBlue),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {
                          _searchQuery = '';
                          _suggestions = [];
                          _showSuggestions = false;
                        });
                        _fetchRecommendations();
                      })
                  : null,
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(26),
                borderSide: BorderSide.none,
              ),
            ),
            ),
          ),
        ),
        if (_showSuggestions)
          Container(
            margin: const EdgeInsets.only(top: 6),
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.08),
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
                leading: Icon(Icons.trending_up,
                    size: 18,
                    color: selected
                        ? AppTheme.primaryBlue
                        : AppTheme.secondaryBlue),
                title: Text(_suggestions[i],
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.normal)),
                onTap: () => _submitSearch(_suggestions[i]),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _adBanner() {
    return FutureBuilder(
      future: _loadAds(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.isEmpty) {
          return const SizedBox.shrink();
        }
        return AdBannerSlider(images: snapshot.data!);
      },
    );
  }

  Future<List<String>> _loadAds() async {
    try {
      final jsonData =
          await rootBundle.loadString('assets/advertisement/ads.json');
      final data = json.decode(jsonData) as Map<String, dynamic>;
      return List<String>.from(data['ads']);
    } catch (_) {
      return [];
    }
  }

  Widget _categorySection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Categories',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(width: 8),
            if (!_liveData && !isLoadingCategories)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('offline',
                    style: TextStyle(
                        fontSize: 10, color: Colors.orange.shade800)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (isLoadingCategories)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(12),
                  child: CircularProgressIndicator()))
        else
          SizedBox(
            height: 96,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: categories.length,
              itemBuilder: (_, i) {
                final cat = Map<String, dynamic>.from(categories[i] as Map);
                final id = cat['id'] is int
                    ? cat['id'] as int
                    : int.tryParse('${cat['id']}');
                return _EmojiCategoryChip(
                  emoji: (cat['emoji'] ?? '🛠️').toString(),
                  label: (cat['name'] ?? '').toString(),
                  selected: _selectedCategoryId == id,
                  onTap: () => _onCategoryTap(cat),
                );
              },
            ),
          ),
      ],
    );
  }

  Widget _recommendations() {
    final isDefaultView =
        _selectedCategoryId == null && _searchQuery.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _selectedCategoryId != null
                  ? 'Providers in this category'
                  : _searchQuery.isNotEmpty
                      ? 'Results for "$_searchQuery"'
                      : 'Recommended for You',
              style:
                  const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            if (isDefaultView) _recRefToggle(),
          ],
        ),
        const SizedBox(height: 10),
        if (isLoadingRecommendations)
          const Center(
              child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator()))
        else if (recommendations.isEmpty)
          _emptyState()
        else
          for (final s in recommendations)
            _providerCard(Map<String, dynamic>.from(s as Map)),
      ],
    );
  }

  /// Home / Current location toggle for "Recommended for You" — same
  /// nearest-to-farthest ranking either way, just a different
  /// reference point. Mirrors the Map screen's toggle.
  Widget _recRefToggle() {
    Widget chip(String mode, IconData icon, String label) {
      final active = _recRefMode == mode;
      return GestureDetector(
        onTap: _recLoadingLocation ? null : () => _setRecRefMode(mode),
        child: Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: active ? AppTheme.primaryBlue : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon,
                  size: 14, color: active ? Colors.white : Colors.black54),
              const SizedBox(width: 4),
              Text(label,
                  style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: active ? Colors.white : Colors.black54)),
            ],
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        chip('home', Icons.home_rounded, 'Home'),
        chip('current', Icons.my_location, 'Current'),
      ],
    );
  }

  Widget _emptyState() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const Text('🔍', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 8),
          const Text('No providers yet',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            _liveData
                ? 'Be the first provider in this category — switch to Provider mode from your profile!'
                : 'Please check your connection and pull down to refresh.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.black54),
          ),
        ],
      ),
    );
  }

  Widget _providerCard(Map<String, dynamic> s) {
    return GestureDetector(
      onTap: () => openBookingSheet(context, s),
      child: _providerCardBody(s),
    );
  }

  Widget _providerCardBody(Map<String, dynamic> s) {
    final name = (s['provider_name'] ?? s['name'] ?? 'Provider').toString();
    final title = (s['title'] ?? s['service_title'] ?? '').toString();
    final price = (s['price'] ?? s['base_price'] ?? '—').toString();
    final unit = (s['price_unit'] ?? 'fixed').toString();
    final city = (s['city'] ?? s['area'] ?? '').toString();
    final rating = double.tryParse('${s['average_rating'] ?? 0}') ?? 0;
    final distanceKm = double.tryParse('${s['distance_km'] ?? ''}');

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () {
              final pid = int.tryParse('${s['provider_id']}');
              if (pid == null) return;
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => PublicProfileScreen(
                      userId: pid,
                      fallbackName: name,
                      fallbackAvatar: (s['provider_avatar'] ?? '').toString())));
            },
            child: UserAvatar(
              name: name,
              avatarUrl: (s['provider_avatar'] ?? '').toString(),
              radius: 26,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: () {
                    final pid = int.tryParse('${s['provider_id']}');
                    if (pid == null) return;
                    Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PublicProfileScreen(
                            userId: pid,
                            fallbackName: name,
                            fallbackAvatar:
                                (s['provider_avatar'] ?? '').toString())));
                  },
                  child: Text(name,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 15)),
                ),
                if (title.isNotEmpty)
                  Text(title,
                      style: const TextStyle(
                          color: Colors.black54, fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 0,
                  runSpacing: 4,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(
                        5,
                        (i) => Icon(
                          i < rating.round() ? Icons.star : Icons.star_border,
                          color: Colors.amber,
                          size: 15,
                        ),
                      ),
                    ),
                    if (city.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.location_on,
                                size: 13, color: Colors.grey),
                            const SizedBox(width: 2),
                            Text(city, style: const TextStyle(fontSize: 12)),
                          ],
                        ),
                      ),
                    if (distanceKm != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${distanceKm.toStringAsFixed(distanceKm < 10 ? 1 : 0)} km away',
                            style: const TextStyle(
                                fontSize: 10.5,
                                color: AppTheme.primaryBlue,
                                fontWeight: FontWeight.w600),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: const [
                    Icon(Icons.check_circle, color: Colors.green, size: 15),
                    SizedBox(width: 4),
                    Text('Available',
                        style: TextStyle(color: Colors.green, fontSize: 12)),
                  ],
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('₹$price',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlue,
                      fontSize: 15)),
              Text(
                switch (unit) {
                  'per_hour' => 'per hour',
                  'per_day' => 'per day',
                  _ => 'fixed price',
                },
                style: const TextStyle(fontSize: 10.5, color: Colors.black45),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── BOOKING SHEET ────────────────────────────
}

// ═════════════════════════════════════════════
// EMOJI CATEGORY CHIP
// ═════════════════════════════════════════════
class _EmojiCategoryChip extends StatelessWidget {
  final String emoji;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _EmojiCategoryChip({
    required this.emoji,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        width: 84,
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primaryBlue : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color:
                  selected ? AppTheme.primaryBlue : Colors.blue.shade50,
              width: 1.4),
          boxShadow: [
            BoxShadow(
                color: Colors.black.withOpacity(selected ? 0.12 : 0.04),
                blurRadius: 6,
                offset: const Offset(0, 2)),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 2,
              textAlign: TextAlign.center,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10.5,
                height: 1.1,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Colors.black87,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════
// AD BANNER SLIDER  (unchanged behaviour, kept)
// ═════════════════════════════════════════════
class AdBannerSlider extends StatefulWidget {
  final List<String> images;
  const AdBannerSlider({super.key, required this.images});

  @override
  State<AdBannerSlider> createState() => _AdBannerSliderState();
}

class _AdBannerSliderState extends State<AdBannerSlider> {
  final PageController _controller = PageController();
  int _currentIndex = 0;
  // Bumped once per mount so the ValueKey on each Image.asset below
  // changes, forcing Flutter to build fresh Image widgets rather than
  // reusing ones from a previous slider instance.
  final int _loadGeneration = DateTime.now().millisecondsSinceEpoch;

  @override
  void initState() {
    super.initState();
    // The actual fix for "replaced the image file but the app still
    // shows the old one": Flutter's image cache is keyed by asset
    // path, not file content, so overwriting img1.png's bytes on
    // disk while keeping the same filename doesn't invalidate any
    // copy Flutter already decoded and cached in this session. Evict
    // every ad asset explicitly on each mount so a genuine refresh
    // (e.g. tapping the logo, per this app's existing RefreshBus
    // pattern) always re-decodes from the current file on disk.
    for (final img in widget.images) {
      AssetImage('assets/advertisement/$img').evict();
    }
    _startAutoSlide();
  }

  void _startAutoSlide() {
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 4));
      if (!mounted || !_controller.hasClients) return false;
      int next = _controller.page!.round() + 1;
      if (next == widget.images.length) next = 0;
      _controller.animateToPage(next,
          duration: const Duration(milliseconds: 600),
          curve: Curves.easeInOut);
      return mounted;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.images.length,
              onPageChanged: (i) => setState(() => _currentIndex = i),
              itemBuilder: (_, i) => Container(
                // contain, not cover — img3.png is genuinely 1536×1024
                // (3:2), while the other three are 16:9. Forcing every
                // image through the same fixed 16:9 box with
                // BoxFit.cover was cropping real content off img3's
                // edges (the sidebar text, category icons). contain
                // guarantees nothing is ever cut off regardless of an
                // image's actual dimensions, at the cost of a thin
                // letterbox bar for anything that doesn't match — a
                // fair trade for not losing real content.
                color: Colors.white,
                child: Image.asset(
                  'assets/advertisement/${widget.images[i]}',
                  // Cache-busts on the FILENAME, not just content —
                  // Flutter's asset image cache is keyed by asset
                  // name, so replacing a file's bytes while keeping
                  // the same filename (e.g. re-exporting img1.png
                  // with new content) can keep showing the OLD
                  // cached decode until a full app restart. Keying
                  // on last-modified-at-load forces a fresh decode
                  // whenever the ad list itself is reloaded.
                  key: ValueKey('${widget.images[i]}_$_loadGeneration'),
                  fit: BoxFit.contain,
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(
            widget.images.length,
            (i) => AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              margin: const EdgeInsets.symmetric(horizontal: 3),
              width: _currentIndex == i ? 14 : 8,
              height: 8,
              decoration: BoxDecoration(
                color:
                    _currentIndex == i ? AppTheme.primaryBlue : Colors.grey[400],
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
