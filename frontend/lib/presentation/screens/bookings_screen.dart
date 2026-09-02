// ─────────────────────────────────────────────
// presentation/screens/bookings_screen.dart
//
// Dual-role bookings:
//   Tab 1 — "My Bookings"  : services I booked (seeker side)
//   Tab 2 — "Received"     : bookings on my listings (provider side)
// Provider actions: Accept / Reject / Start / Complete.
// Customer action: Cancel (while pending/accepted).
// ─────────────────────────────────────────────
import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api/booking_api.dart';
import '../../core/services/refresh_bus.dart';
import '../../core/widgets/user_avatar.dart';
import '../../core/widgets/refresh_spinner.dart';
import '../../core/theme/app_theme.dart';
import 'chat_screen.dart';
import 'public_profile_screen.dart';
import 'booking_route_screen.dart';
import '../../core/utils/time_format.dart' show parseServerTime;

class BookingsScreen extends StatefulWidget {
  const BookingsScreen({super.key});

  @override
  State<BookingsScreen> createState() => _BookingsScreenState();
}

class _BookingsScreenState extends State<BookingsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tab;

  List<dynamic> _mine = [];
  List<dynamic> _received = [];
  bool _loadingMine = true;
  bool _loadingReceived = true;
  String? _error;

  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
    _loadAll();
    // Refresh instantly whenever a booking is created/changed anywhere
    // in the app (e.g. from Home's Recommended for You) — closes the
    // "new booking not showing up" gap regardless of tab-caching.
    RefreshBus.bookings.addListener(_onBookingsChangedElsewhere);
    // Catches the OTHER case the listener above can't: a status
    // change made by the OTHER PARTY (provider accepts while the
    // customer already has this screen open, etc). Silent so it
    // doesn't flash the loading spinner every cycle.
    _poll = Timer.periodic(
        const Duration(seconds: 15), (_) => _loadAll(silent: true));
  }

  void _onBookingsChangedElsewhere() {
    if (mounted) _loadAll();
  }

  @override
  void dispose() {
    RefreshBus.bookings.removeListener(_onBookingsChangedElsewhere);
    _poll?.cancel();
    _tab.dispose();
    super.dispose();
  }

  Future<void> _loadAll({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loadingMine = true;
        _loadingReceived = true;
        _error = null;
      });
    }
    final results = await Future.wait(
        [BookingApi.getMyBookings(), BookingApi.getReceivedBookings()]);
    if (!mounted) return;
    setState(() {
      _loadingMine = false;
      _loadingReceived = false;
      if (results[0].success && results[0].data is Map) {
        _mine = results[0].data['bookings'] ?? [];
        _error = null; // a successful poll proves connectivity is back
      } else if (!silent && results[0].isOffline) {
        _error =
            'Unable to connect. Please check your connection and try again.';
      }
      if (results[1].success && results[1].data is Map) {
        _received = results[1].data['bookings'] ?? [];
      }
    });
  }

  Future<void> _act(int id, String action,
      {String? reason,
      DateTime? proposedTime,
      double? advanceAmount,
      DateTime? paymentDeadline,
      String? successMsg}) async {
    final res = await BookingApi.action(id, action,
        reason: reason,
        proposedTime: proposedTime,
        advanceAmount: advanceAmount,
        paymentDeadline: paymentDeadline);
    if (!mounted) return;
    if (res.success) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(successMsg ?? 'Done — ${action.replaceAll('_', ' ')}')));
      _loadAll();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res.isOffline
              ? 'Unable to connect. Please check your connection.'
              : res.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          decoration: const BoxDecoration(
            gradient: AppTheme.gmsGradient,
            borderRadius: BorderRadius.only(
              bottomLeft: Radius.circular(20),
              bottomRight: Radius.circular(20),
            ),
          ),
          child: Column(
            children: [
              // Same GMS brand row used on every tab — no menu icon here.
              GestureDetector(
                onTap: () => RefreshBus.bumpAll(),
                child: Row(
                  children: [
                    Image.asset('assets/images/gms_logo.png', height: 26),
                    const SizedBox(width: 10),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Text('Get My Service',
                                style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 18,
                                    color: Colors.white)),
                            SizedBox(width: 6),
                            RefreshSpinner(),
                          ],
                        ),
                        const Text('Any service. Any time. One app.',
                            style: TextStyle(
                                fontSize: 10.5, color: Colors.white70)),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              TabBar(
                controller: _tab,
                indicatorColor: Colors.white,
                indicatorWeight: 3,
                labelColor: Colors.white,
                unselectedLabelColor: Colors.white60,
                labelStyle: const TextStyle(fontWeight: FontWeight.w600),
                tabs: const [
                  Tab(text: 'My Bookings'),
                  Tab(text: 'Received'),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _list(_mine, _loadingMine, asProvider: false),
              _list(_received, _loadingReceived, asProvider: true),
            ],
          ),
        ),
      ],
    );
  }

  Widget _list(List<dynamic> items, bool loading,
      {required bool asProvider}) {
    return RefreshIndicator(
      color: AppTheme.primaryBlue,
      onRefresh: _loadAll,
      child: loading
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
              ? ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  children: [
                    const SizedBox(height: 100),
                    Center(
                        child: Text(asProvider ? '📥' : '📋',
                            style: const TextStyle(fontSize: 44))),
                    const SizedBox(height: 12),
                    Center(
                      child: Text(
                        _error ??
                            (asProvider
                                ? 'No bookings received yet.\nAdd a service from your profile to start earning!'
                                : 'No bookings yet.\nFind a service from the Home tab!'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.black54),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.all(14),
                  itemCount: items.length,
                  itemBuilder: (_, i) => _bookingCard(
                      Map<String, dynamic>.from(items[i] as Map),
                      asProvider: asProvider),
                ),
    );
  }

  Widget _bookingCard(Map<String, dynamic> b, {required bool asProvider}) {
    final id = int.tryParse('${b['id']}') ?? 0;
    final status = (b['status'] ?? 'pending').toString();
    final title = (b['service_title'] ?? '').toString();
    final category = (b['category_name'] ?? '').toString();
    final otherName =
        (asProvider ? b['customer_name'] : b['provider_name'])?.toString() ??
            '';
    final otherId = int.tryParse(
            '${asProvider ? b['customer_id'] : b['provider_id']}') ??
        0;
    final otherAvatar =
        (asProvider ? b['customer_avatar'] : b['provider_avatar'])?.toString();
    final price = (b['service_price'] ?? '—').toString();
    final scheduled = (b['scheduled_at'] ?? '').toString();
    final address = (b['address'] ?? '').toString();
    // My Bookings (asProvider=false): the provider is coming to ME —
    // origin = provider's registered location, destination = MY
    // location as it was saved on THIS booking (never a live
    // re-fetch, since I may have moved since I actually booked).
    // Received (asProvider=true): I'm going to THEM — origin = my
    // live current location, destination = the customer's saved
    // booking-time point.
    final providerLat = double.tryParse('${b['provider_lat']}');
    final providerLng = double.tryParse('${b['provider_lng']}');
    final customerLat = double.tryParse('${b['customer_lat']}');
    final customerLng = double.tryParse('${b['customer_lng']}');
    final routeLat = asProvider ? customerLat : providerLat;
    final routeLng = asProvider ? customerLng : providerLng;

    final advance = (b['advance_amount'] ?? '').toString();
    final advancePaid = b['advance_paid'] == 1 || b['advance_paid'] == true;
    final proposed = (b['proposed_time'] ?? '').toString();
    final reasonTxt = (b['cancel_reason'] ?? '').toString();
    final deadline = (b['payment_deadline'] ?? '').toString();

    return GestureDetector(
      onTap: () => _showTimeline(id, title),
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 15)),
              ),
              _statusChip(status),
            ],
          ),
          const SizedBox(height: 4),
          Text('$category  •  ₹$price',
              style: const TextStyle(color: Colors.black54, fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [
              GestureDetector(
                onTap: otherId > 0
                    ? () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => PublicProfileScreen(
                            userId: otherId,
                            fallbackName: otherName,
                            fallbackAvatar: otherAvatar)))
                    : null,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    UserAvatar(
                        name: otherName, avatarUrl: otherAvatar, radius: 12),
                    const SizedBox(width: 6),
                    Text(
                      asProvider ? 'From: $otherName' : 'By: $otherName',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (otherId > 0)
                InkWell(
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => ChatThreadScreen(
                          partnerId: otherId,
                          partnerName: otherName,
                          partnerAvatar: otherAvatar))),
                  child: Row(
                    children: const [
                      Icon(Icons.chat_bubble_outline,
                          size: 15, color: AppTheme.primaryBlue),
                      SizedBox(width: 4),
                      Text('Chat',
                          style: TextStyle(
                              color: AppTheme.primaryBlue,
                              fontSize: 13,
                              fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
            ],
          ),
          if (scheduled.isNotEmpty && scheduled != 'null') ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(Icons.event, size: 15, color: Colors.grey),
                const SizedBox(width: 4),
                Text(_prettyDate(scheduled),
                    style: const TextStyle(fontSize: 13)),
              ],
            ),
          ],
          if (address.isNotEmpty && address != 'null') ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: (asProvider
                      ? (customerLat != null && customerLng != null)
                      : (providerLat != null &&
                          providerLng != null &&
                          customerLat != null &&
                          customerLng != null))
                  ? () {
                      if (asProvider) {
                        // Received: I'm traveling to them — origin is
                        // fetched live inside the route screen (I'm
                        // heading there today), destination is the
                        // customer's saved booking-time location.
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => BookingRouteScreen(
                            title: 'Route to $otherName',
                            originIsLiveMe: true,
                            originLabel: 'Your current location',
                            originEmoji: '🧑‍🔧',
                            destLat: routeLat,
                            destLng: routeLng,
                            destLabel: '$otherName • $address',
                            destEmoji: '🙂',
                          ),
                        ));
                      } else {
                        // My Bookings: the provider is coming to me —
                        // both ends are fixed historical facts about
                        // this exact booking, no live GPS involved.
                        Navigator.of(context).push(MaterialPageRoute(
                          builder: (_) => BookingRouteScreen(
                            title: '$otherName is coming to you',
                            originLat: routeLat,
                            originLng: routeLng,
                            originLabel: otherName,
                            originEmoji: '🚗',
                            destLat: customerLat,
                            destLng: customerLng,
                            destLabel: 'You • $address',
                            destEmoji: '🙂',
                          ),
                        ));
                      }
                    }
                  : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.location_on_outlined,
                      size: 15,
                      color: routeLat != null
                          ? AppTheme.primaryBlue
                          : Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                      child: Text(address,
                          style: TextStyle(
                              fontSize: 13,
                              color: routeLat != null
                                  ? AppTheme.primaryBlue
                                  : Colors.black54,
                              decoration: routeLat != null
                                  ? TextDecoration.underline
                                  : null))),
                ],
              ),
            ),
          ],
          if (status == 'completed' ||
              (advance.isNotEmpty &&
                  advance != 'null' &&
                  advance != '0.00')) ...[
            const SizedBox(height: 6),
            Row(children: [
              Icon(
                  status == 'completed'
                      ? Icons.task_alt
                      : (advancePaid ? Icons.verified : Icons.currency_rupee),
                  size: 15,
                  color: (status == 'completed' || advancePaid)
                      ? Colors.green
                      : Colors.amber.shade800),
              const SizedBox(width: 4),
              Text(
                status == 'completed'
                    // Service is done — the two-step advance model has
                    // served its purpose; show the full price as settled
                    // rather than repeating "advance paid" on a
                    // finished job.
                    ? 'Fully Paid ✅  (₹$price)'
                    : advancePaid
                        ? 'Advance ₹$advance paid ✅'
                        : 'Advance ₹$advance required to confirm',
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: (status == 'completed' || advancePaid)
                        ? Colors.green
                        : Colors.amber.shade900),
              ),
            ]),
            if (!advancePaid &&
                status != 'completed' &&
                deadline.isNotEmpty &&
                deadline != 'null')
              Padding(
                padding: const EdgeInsets.only(left: 19, top: 2),
                child: Text('Pay before ${_prettyDate(deadline)}',
                    style: const TextStyle(
                        fontSize: 11.5, color: Colors.black45)),
              ),
          ],
          if (proposed.isNotEmpty && proposed != 'null') ...[
            const SizedBox(height: 6),
            Row(children: [
              const Icon(Icons.update, size: 15, color: Colors.teal),
              const SizedBox(width: 4),
              Text('Proposed new time: ${_prettyDate(proposed)}',
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: Colors.teal,
                      fontWeight: FontWeight.w600)),
            ]),
          ],
          if (reasonTxt.isNotEmpty && reasonTxt != 'null') ...[
            const SizedBox(height: 6),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Icon(Icons.info_outline, size: 15, color: Colors.grey),
              const SizedBox(width: 4),
              Expanded(
                child: Text('Reason: $reasonTxt',
                    style: const TextStyle(
                        fontSize: 12, color: Colors.black54)),
              ),
            ]),
          ],
          ..._actions(id, status, asProvider: asProvider),
          const SizedBox(height: 6),
          const Align(
            alignment: Alignment.centerRight,
            child: Text('Tap for timeline ⏱',
                style: TextStyle(fontSize: 10.5, color: Colors.black38)),
          ),
        ],
      ),
      ),
    );
  }

  /// Booking timeline bottom sheet — every action with timestamps.
  Future<void> _showTimeline(int id, String title) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (ctx) => FutureBuilder(
        future: BookingApi.getEvents(id),
        builder: (ctx, snap) {
          if (!snap.hasData) {
            return const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator()));
          }
          final res = snap.data!;
          final events = (res.success && res.data is Map)
              ? List<Map<String, dynamic>>.from(
                  (res.data['events'] as List? ?? [])
                      .map((e) => Map<String, dynamic>.from(e)))
              : <Map<String, dynamic>>[];
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 30),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Timeline — $title',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 14),
                if (events.isEmpty)
                  const Text('No timeline events yet.',
                      style: TextStyle(color: Colors.black54))
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 380),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: events.length,
                      itemBuilder: (_, i) {
                        final e = events[i];
                        final action =
                            (e['action'] ?? '').toString().replaceAll('_', ' ');
                        final who = (e['actor_name'] ?? '').toString();
                        final when = _prettyDate('${e['created_at']}');
                        final reason = (e['reason'] ?? '').toString();
                        final prop = (e['proposed_time'] ?? '').toString();
                        final amt = (e['amount'] ?? '').toString();
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Column(children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  margin: const EdgeInsets.only(top: 4),
                                  decoration: const BoxDecoration(
                                      color: AppTheme.primaryBlue,
                                      shape: BoxShape.circle),
                                ),
                                if (i != events.length - 1)
                                  Container(
                                      width: 2,
                                      height: 34,
                                      color: Colors.blue.shade100),
                              ]),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                        '${action[0].toUpperCase()}${action.substring(1)} — $who',
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600,
                                            fontSize: 13.5)),
                                    Text(when,
                                        style: const TextStyle(
                                            fontSize: 11.5,
                                            color: Colors.black45)),
                                    if (amt.isNotEmpty && amt != 'null')
                                      Text('Amount: ₹$amt',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.black54)),
                                    if (prop.isNotEmpty && prop != 'null')
                                      Text('Proposed: ${_prettyDate(prop)}',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.teal)),
                                    if (reason.isNotEmpty && reason != 'null')
                                      Text('Reason: $reason',
                                          style: const TextStyle(
                                              fontSize: 12,
                                              color: Colors.black54)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  List<Widget> _actions(int id, String status, {required bool asProvider}) {
    final buttons = <Widget>[];

    if (asProvider) {
      switch (status) {
        case 'pending':
          buttons.addAll([
            _actionBtn('Accept', Colors.green, () => _acceptDialog(id)),
            _actionBtn('Reject', Colors.red, () => _rejectDialog(id)),
            _actionBtn('New Time', Colors.teal,
                () => _proposeDialog(id, action: 'reschedule')),
          ]);
          break;
        case 'reschedule_by_customer':
          buttons.addAll([
            _actionBtn('Accept Time', Colors.green, () => _acceptDialog(id)),
            _actionBtn('Another Time', Colors.teal,
                () => _proposeDialog(id, action: 'reschedule')),
            _actionBtn('Reject', Colors.red, () => _rejectDialog(id)),
          ]);
          break;
        case 'confirmed':
          buttons.add(_actionBtn('Start Visit', AppTheme.primaryBlue,
              () => _confirmThen(id, 'start', 'Start this service visit?')));
          break;
        case 'in_progress':
          buttons.add(_actionBtn('Mark Completed', Colors.green,
              () => _confirmThen(id, 'complete', 'Mark this service as completed?')));
          break;
        case 'awaiting_advance':
        case 'reschedule_by_provider':
          buttons.add(_actionBtn('Cancel Booking', Colors.red,
              () => _cancelDialog(id)));
          break;
      }
    } else {
      switch (status) {
        case 'awaiting_advance':
          buttons.addAll([
            _actionBtn('Pay Advance', Colors.green, () => _payDialog(id)),
            _actionBtn('Reschedule', Colors.teal,
                () => _proposeDialog(id, action: 'counter_proposal')),
            _actionBtn('Cancel', Colors.red, () => _cancelDialog(id)),
          ]);
          break;
        case 'reschedule_by_provider':
          buttons.addAll([
            _actionBtn('Accept New Time', Colors.green,
                () => _confirmThen(id, 'accept_proposal',
                    'Accept the provider\'s proposed time?')),
            _actionBtn('Suggest Another', Colors.teal,
                () => _proposeDialog(id, action: 'counter_proposal')),
            _actionBtn('Reject', Colors.red, () => _cancelDialog(id,
                title: 'Reject this booking?',
                confirmLabel: 'Confirm Reject')),
          ]);
          break;
        case 'pending':
        case 'confirmed':
          buttons.addAll([
            _actionBtn('Suggest New Time', Colors.teal,
                () => _proposeDialog(id, action: 'counter_proposal')),
            _actionBtn('Cancel', Colors.red, () => _cancelDialog(id)),
          ]);
          break;
        case 'reschedule_by_customer':
          buttons.add(_actionBtn('Cancel', Colors.red, () => _cancelDialog(id)));
          break;
      }
    }

    if (buttons.isEmpty) return [];
    return [
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final b in buttons)
          SizedBox(width: buttons.length > 2 ? 106 : 150, child: b),
      ]),
    ];
  }

  /// Generic confirmation before simple actions (spec: every action confirmed)
  Future<void> _confirmThen(int id, String action, String question) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(question),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Confirm')),
        ],
      ),
    );
    if (ok == true) _act(id, action);
  }

  /// Provider Accept: sets the advance amount (two-step verification!)
  Future<void> _acceptDialog(int id) async {
    final b = [..._mine, ..._received]
        .map((e) => Map<String, dynamic>.from(e as Map))
        .firstWhere((e) => int.tryParse('${e['id']}') == id,
            orElse: () => {});
    final servicePrice = double.tryParse('${b['service_price'] ?? 0}') ?? 0;
    // Preview only — the backend is the actual source of truth and
    // calculates this itself from platform_config's advance_percent,
    // currently 25%. Shown here so the provider knows what the
    // customer will be asked to pay before confirming.
    final advancePreview = (servicePrice * 0.25);

    int deadlineHours = 24;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Accept booking'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Booking confirms once the customer pays the advance below — 25% of your service price, calculated automatically.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Advance due from customer',
                        style: TextStyle(fontSize: 13)),
                    Text('₹${advancePreview.toStringAsFixed(2)}',
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700)),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<int>(
                initialValue: deadlineHours,
                decoration:
                    const InputDecoration(labelText: 'Payment deadline'),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('No deadline')),
                  DropdownMenuItem(value: 12, child: Text('12 hours')),
                  DropdownMenuItem(value: 24, child: Text('24 hours')),
                  DropdownMenuItem(value: 48, child: Text('48 hours')),
                ],
                onChanged: (v) => setD(() => deadlineHours = v ?? 0),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Back')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Accept Booking')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _act(id, 'accept',
        paymentDeadline: deadlineHours > 0
            ? DateTime.now().add(Duration(hours: deadlineHours))
            : null,
        successMsg: advancePreview > 0
            ? 'Accepted — advance of ₹${advancePreview.toStringAsFixed(0)} requested'
            : 'Booking confirmed (no advance)');
  }

  /// Rejection — reason is MANDATORY
  Future<void> _rejectDialog(int id) async {
    const reasons = [
      'Not available on requested date',
      'Already booked',
      'Outside service area',
      'Personal reasons',
      'Other (type below)',
    ];
    String selected = reasons.first;
    final customCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Reject booking'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<String>(
                initialValue: selected,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Reason (required)'),
                items: [
                  for (final r in reasons)
                    DropdownMenuItem(value: r, child: Text(r, overflow: TextOverflow.ellipsis)),
                ],
                onChanged: (v) => setD(() => selected = v ?? reasons.first),
              ),
              if (selected.startsWith('Other')) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: customCtrl,
                  decoration:
                      const InputDecoration(labelText: 'Custom reason'),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Back')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:
                    const Text('Reject', style: TextStyle(color: Colors.red))),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final reason = selected.startsWith('Other')
        ? customCtrl.text.trim()
        : selected;
    if (reason.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('A rejection reason is required')));
      return;
    }
    _act(id, 'reject', reason: reason, successMsg: 'Booking rejected');
  }

  /// New-time proposal (provider reschedule OR customer counter) — the
  /// unlimited negotiation loop lives here.
  Future<void> _proposeDialog(int id, {required String action}) async {
    final date = await showDatePicker(
      context: context,
      initialDate: DateTime.now().add(const Duration(days: 1)),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 60)),
      helpText: 'Pick the new date',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
        context: context, initialTime: const TimeOfDay(hour: 10, minute: 0));
    if (time == null || !mounted) return;
    final dt = DateTime(date.year, date.month, date.day, time.hour, time.minute);

    final reasonCtrl = TextEditingController();
    String? inlineError;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Propose new time'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Proposed: ${dt.day}/${dt.month}/${dt.year}  '
                  '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}'),
              const SizedBox(height: 12),
              TextField(
                controller: reasonCtrl,
                decoration: InputDecoration(
                  labelText: 'Reason (required)',
                  errorText: inlineError,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Back')),
            TextButton(
              onPressed: () {
                // A reason is required for BOTH the provider's
                // reschedule and the customer's counter-proposal —
                // previously only the provider side enforced this,
                // and even then the dialog closed first and showed
                // a separate error after the fact rather than
                // blocking the close outright.
                if (reasonCtrl.text.trim().isEmpty) {
                  setD(() => inlineError = 'A reason is required');
                  return;
                }
                Navigator.pop(ctx, true);
              },
              child: const Text('Send Proposal'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final reason = reasonCtrl.text.trim();
    _act(id, action,
        proposedTime: dt,
        reason: reason,
        successMsg: 'New time proposed');
  }

  /// Advance payment (simulated for MVP — gateway comes later)
  Future<void> _payDialog(int id) async {
    final b = [..._mine, ..._received]
        .map((e) => Map<String, dynamic>.from(e as Map))
        .firstWhere((e) => int.tryParse('${e['id']}') == id,
            orElse: () => {});
    final amt = (b['advance_amount'] ?? '—').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Pay ₹$amt advance?'),
        content: const Text(
            'Paying the advance confirms your booking instantly. '
            '(Test mode — no real money moves yet.)'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Pay & Confirm')),
        ],
      ),
    );
    if (ok == true) {
      _act(id, 'pay_advance', successMsg: 'Advance paid — booking confirmed ✅');
    }
  }

  Future<void> _cancelDialog(int id, {String? title, String? confirmLabel}) async {
    final reasonCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title ?? 'Cancel booking?'),
        content: TextField(
          controller: reasonCtrl,
          decoration: const InputDecoration(hintText: 'Reason (optional)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Back')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(confirmLabel ?? 'Confirm Cancel',
                  style: const TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (ok == true) {
      _act(id, 'cancel',
          reason: reasonCtrl.text.trim().isEmpty ? null : reasonCtrl.text.trim(),
          successMsg: 'Booking cancelled');
    }
  }

  Widget _actionBtn(String label, Color color, VoidCallback onTap) {
    return OutlinedButton(
      onPressed: onTap,
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withOpacity(0.6)),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      child: Text(label,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
    );
  }

  Widget _statusChip(String status) {
    final (color, label) = switch (status) {
      'pending' => (Colors.orange, 'Pending Provider Response'),
      'awaiting_advance' => (Colors.amber, 'Awaiting Advance Payment'),
      'confirmed' => (Colors.blue, 'Confirmed'),
      'in_progress' => (Colors.purple, 'Visiting'),
      'completed' => (Colors.green, 'Completed'),
      'reschedule_by_provider' => (Colors.teal, 'Reschedule: Provider Proposed'),
      'reschedule_by_customer' => (Colors.cyan, 'Reschedule: You Proposed'),
      'rejected' => (Colors.red, 'Rejected'),
      'cancelled_by_customer' => (Colors.red, 'Cancelled by Customer'),
      'cancelled_by_provider' => (Colors.red, 'Cancelled by Provider'),
      'expired' => (Colors.blueGrey, 'Expired'),
      _ => (Colors.grey, status),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
    );
  }

  String _prettyDate(String iso) {
    final dt = parseServerTime(iso);
    if (dt == null) return iso;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final ampm = dt.hour >= 12 ? 'PM' : 'AM';
    return '${dt.day} ${months[dt.month - 1]}, $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
  }
}
