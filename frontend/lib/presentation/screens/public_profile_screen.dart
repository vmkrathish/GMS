// ─────────────────────────────────────────────
// presentation/screens/public_profile_screen.dart
//
// Read-only view of ANOTHER user's profile — tapped from a name
// or avatar anywhere in the app (Home search results, Chat,
// Bookings). Shows only what GET /api/users/:id exposes
// (name, city, bio, avatar_url, role) — never email, phone, or
// full address, which stay private to the account owner.
// ─────────────────────────────────────────────
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/api/service_api.dart';
import '../../core/api/user_api.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/booking_sheet.dart';
import '../../core/widgets/user_avatar.dart';
import '../../core/utils/time_format.dart';
import 'chat_screen.dart';
import 'route_to_provider_screen.dart';

class PublicProfileScreen extends StatefulWidget {
  final int userId;
  final String fallbackName;
  final String? fallbackAvatar;

  const PublicProfileScreen({
    super.key,
    required this.userId,
    this.fallbackName = '',
    this.fallbackAvatar,
  });

  @override
  State<PublicProfileScreen> createState() => _PublicProfileScreenState();
}

class _PublicProfileScreenState extends State<PublicProfileScreen> {
  Map<String, dynamic>? _user;
  List<dynamic> _services = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait([
      UserApi.getUserById(widget.userId),
      ServiceApi.getServices(providerId: widget.userId),
    ]);
    if (!mounted) return;

    final userRes = results[0];
    final svcRes = results[1];
    setState(() {
      if (userRes.success && userRes.data is Map) {
        _user = Map<String, dynamic>.from(userRes.data['user'] ?? {});
      }
      if (svcRes.success && svcRes.data is Map) {
        _services = svcRes.data['services'] ?? [];
      }
      _loading = false;
    });
  }

  void _showReviews(BuildContext context, int providerId, double rating,
      int reviewTotal) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _ReviewsSheet(
        providerId: providerId,
        rating: rating,
        reviewTotal: reviewTotal,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final name = (_user?['name'] ?? widget.fallbackName).toString();
    final avatar =
        (_user?['avatar_url'] ?? widget.fallbackAvatar ?? '').toString();
    final city = (_user?['city'] ?? '').toString();
    final bio = (_user?['bio'] ?? '').toString();
    final _lat = double.tryParse('${_user?['latitude']}');
    final _lng = double.tryParse('${_user?['longitude']}');

    // average_rating and review_count are PROVIDER-level values (see
    // RATING_SQL in services.py) — every one of this provider's
    // services carries the SAME number, not a per-service count.
    // Summing across all services was multiplying the real count by
    // however many services this provider offers (1 real review + 2
    // services was showing as "2 reviews"). Take it once instead.
    final rating = _services.isNotEmpty
        ? double.tryParse('${_services.first['average_rating'] ?? 0}') ?? 0.0
        : 0.0;
    final reviewTotal = _services.isNotEmpty
        ? int.tryParse('${_services.first['review_count'] ?? 0}') ?? 0
        : 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7FB),
      appBar: AppBar(
        elevation: 0,
        title: const Text('Profile',
            style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white)),
        centerTitle: true,
        iconTheme: const IconThemeData(color: Colors.white),
        flexibleSpace: Container(
          decoration: const BoxDecoration(gradient: AppTheme.gmsGradient),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              color: AppTheme.primaryBlue,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(20),
                children: [
                  Center(
                    child: GestureDetector(
                      onTap: () => showReadOnlyAvatarViewer(context,
                          avatarUrl: avatar, name: name),
                      child: UserAvatar(
                          name: name, avatarUrl: avatar, radius: 44),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(name,
                        textAlign: TextAlign.center,
                        style: GoogleFonts.playfairDisplay(
                          fontSize: 24,
                          fontWeight: FontWeight.w700,
                          color: const Color(0xFF1A2B4A),
                          letterSpacing: 0.3,
                        )),
                  ),
                  if (city.isNotEmpty)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Material(
                          color: AppTheme.primaryBlue.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(20),
                            onTap: _lat != null && _lng != null
                                ? () {
                                    Navigator.of(context)
                                        .push(MaterialPageRoute(
                                      builder: (_) => RouteToProviderScreen(
                                        providerId: widget.userId,
                                        providerName: name,
                                        providerLat: _lat!,
                                        providerLng: _lng!,
                                        providerAvatar: avatar,
                                      ),
                                    ));
                                  }
                                : null,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.near_me_rounded,
                                      size: 14, color: AppTheme.primaryBlue),
                                  const SizedBox(width: 5),
                                  Text(city,
                                      style: const TextStyle(
                                          color: AppTheme.primaryBlue,
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13)),
                                  if (_lat != null) ...[
                                    const SizedBox(width: 4),
                                    Icon(Icons.chevron_right,
                                        size: 16,
                                        color: AppTheme.primaryBlue
                                            .withOpacity(0.6)),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (reviewTotal > 0)
                    Center(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => _showReviews(context, widget.userId, rating,
                            reviewTotal),
                        child: Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ...List.generate(
                                5,
                                (i) => Icon(
                                  i < rating.round()
                                      ? Icons.star
                                      : Icons.star_border,
                                  color: Colors.amber,
                                  size: 18,
                                ),
                              ),
                              const SizedBox(width: 6),
                              Text('${rating.toStringAsFixed(1)} ($reviewTotal)',
                                  style: const TextStyle(fontSize: 13)),
                              const SizedBox(width: 4),
                              Icon(Icons.chevron_right,
                                  size: 16, color: Colors.grey.shade500),
                            ],
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 20),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => ChatThreadScreen(
                                  partnerId: widget.userId,
                                  partnerName: name,
                                  partnerAvatar: avatar))),
                      icon: const Icon(Icons.chat_bubble_outline),
                      label: const Text('Message'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  if (bio.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text('About',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Text(bio,
                        style: const TextStyle(
                            fontSize: 14, color: Colors.black87, height: 1.4)),
                  ],
                  if (_services.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    const Text('Services offered',
                        style: TextStyle(
                            fontSize: 15, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 10),
                    for (final raw in _services)
                      _serviceRow(Map<String, dynamic>.from(raw as Map)),
                  ],
                ],
              ),
            ),
    );
  }

  Widget _serviceRow(Map<String, dynamic> s) {
    final emoji = (s['category_emoji'] ?? '🛠️').toString();
    final unit = (s['price_unit'] ?? 'fixed').toString();
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => openBookingSheet(context, s),
      child: Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 6,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Row(
        children: [
          Text(emoji, style: const TextStyle(fontSize: 24)),
          const SizedBox(width: 12),
          Expanded(
            child: Text((s['title'] ?? '').toString(),
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 14)),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('₹${s['price']}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlue)),
              Text(
                switch (unit) {
                  'per_hour' => 'per hour',
                  'per_day' => 'per day',
                  _ => 'fixed price',
                },
                style: const TextStyle(fontSize: 10, color: Colors.black45),
              ),
            ],
          ),
        ],
      ),
      ),
    );
  }
}

class _ReviewsSheet extends StatefulWidget {
  final int providerId;
  final double rating;
  final int reviewTotal;

  const _ReviewsSheet({
    required this.providerId,
    required this.rating,
    required this.reviewTotal,
  });

  @override
  State<_ReviewsSheet> createState() => _ReviewsSheetState();
}

class _ReviewsSheetState extends State<_ReviewsSheet> {
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = false;
  String? _error;
  List<Map<String, dynamic>> _reviews = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await UserApi.getProviderReviews(widget.providerId);
    if (!mounted) return;
    if (res.success && res.data is Map && res.data['reviews'] is List) {
      setState(() {
        _reviews = (res.data['reviews'] as List)
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        _hasMore = res.data['has_more'] == true;
        _loading = false;
      });
    } else {
      setState(() {
        _error = 'Could not load reviews right now.';
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    final res = await UserApi.getProviderReviews(widget.providerId,
        offset: _reviews.length);
    if (!mounted) return;
    if (res.success && res.data is Map && res.data['reviews'] is List) {
      setState(() {
        _reviews.addAll((res.data['reviews'] as List)
            .map((e) => Map<String, dynamic>.from(e)));
        _hasMore = res.data['has_more'] == true;
        _loadingMore = false;
      });
    } else {
      setState(() => _loadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.3,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  const Icon(Icons.star, color: Colors.amber, size: 20),
                  const SizedBox(width: 6),
                  Text(
                    '${widget.rating.toStringAsFixed(1)} · ${widget.reviewTotal} review${widget.reviewTotal == 1 ? '' : 's'}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(_error!,
                                style:
                                    const TextStyle(color: Colors.black54)),
                          ),
                        )
                      : _reviews.isEmpty
                          ? const Center(
                              child: Padding(
                                padding: EdgeInsets.all(24),
                                child: Text('No reviews yet.',
                                    style: TextStyle(color: Colors.black54)),
                              ),
                            )
                          : ListView.separated(
                              controller: scrollController,
                              padding: const EdgeInsets.all(16),
                              itemCount: _reviews.length + (_hasMore ? 1 : 0),
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 24),
                              itemBuilder: (_, i) {
                                if (i == _reviews.length) {
                                  return Center(
                                    child: _loadingMore
                                        ? const Padding(
                                            padding: EdgeInsets.all(12),
                                            child: SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2)),
                                          )
                                        : TextButton(
                                            onPressed: _loadMore,
                                            child: const Text('Load more'),
                                          ),
                                  );
                                }
                                final r = _reviews[i];
                                final rating =
                                    int.tryParse('${r['rating']}') ?? 0;
                                final created =
                                    parseServerTime('${r['created_at']}');
                                return Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    UserAvatar(
                                      name: (r['customer_name'] ?? '')
                                          .toString(),
                                      avatarUrl: r['customer_avatar'],
                                      radius: 18,
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  (r['customer_name'] ?? '')
                                                      .toString(),
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      fontSize: 14),
                                                ),
                                              ),
                                              if (created != null)
                                                Text(
                                                  formatRelativeAgo(created),
                                                  style: const TextStyle(
                                                      fontSize: 11.5,
                                                      color: Colors.black45),
                                                ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Row(
                                            children: List.generate(
                                              5,
                                              (i) => Icon(
                                                i < rating
                                                    ? Icons.star
                                                    : Icons.star_border,
                                                color: Colors.amber,
                                                size: 14,
                                              ),
                                            ),
                                          ),
                                          if ((r['comment'] ?? '')
                                              .toString()
                                              .isNotEmpty) ...[
                                            const SizedBox(height: 6),
                                            Text(
                                              r['comment'].toString(),
                                              style: const TextStyle(
                                                  fontSize: 13.5,
                                                  color: Colors.black87,
                                                  height: 1.35),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
            ),
          ],
        );
      },
    );
  }
}
