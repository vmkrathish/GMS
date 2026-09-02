// lib/presentation/screens/notifications_screen.dart
import 'package:flutter/material.dart';
import 'package:intl/intl.dart'; // add intl to pubspec if not present
import 'package:shimmer/shimmer.dart';
import '../../core/models/notification_model.dart';
import '../../core/models/notification_service.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with SingleTickerProviderStateMixin {
  final NotificationService _service = NotificationService();
  late TabController _tabController;
  final List<String> tabs = const [
    "All",
    "Bookings",
    "Payments",
    "System Alerts",
  ];

  bool _loading = true;
  bool _loadingMore = false;
  List<AppNotification> _items = [];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: tabs.length, vsync: this);
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final data = await _service.fetchNotifications();
    setState(() {
      _items = data;
      _loading = false;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_service.hasMore) return;
    setState(() => _loadingMore = true);
    final data = await _service.loadMore();
    setState(() {
      _items = data;
      _loadingMore = false;
    });
  }

  // helpers to filter by tab
  List<AppNotification> _itemsForTab(int index) {
    if (index == 0) return _items;
    if (index == 1)
      return _items.where((n) => n.type == NotificationType.booking).toList();
    if (index == 2)
      return _items.where((n) => n.type == NotificationType.payment).toList();
    return _items.where((n) => n.type == NotificationType.system).toList();
  }

  // group by date: Today / Yesterday / Older
  Map<String, List<AppNotification>> _groupByDate(List<AppNotification> list) {
    final Map<String, List<AppNotification>> map = {};
    final today = DateTime.now();
    for (var n in list) {
      final d = n.createdAt;
      String key;
      if (_isSameDay(d, today)) {
        key = "Today";
      } else if (_isSameDay(d, today.subtract(const Duration(days: 1)))) {
        key = "Yesterday";
      } else {
        key = DateFormat.yMMMMd().format(d); // e.g. Oct 12, 2025
      }
      map.putIfAbsent(key, () => []).add(n);
    }
    return map;
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  // ----- UI -----
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F6F9),
      appBar: AppBar(
        elevation: 0,
        title: const Text(
          "Notifications",
          style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
        ),
        centerTitle: true,
        flexibleSpace: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
            ),
          ),
        ),
        actions: [
          // Mark all read button
          IconButton(
            tooltip: 'Mark all read',
            onPressed: () async {
              await _service.markAllRead();
              await _load();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("All notifications marked read"),
                  ),
                );
              }
            },
            icon: const Icon(Icons.mark_email_read_rounded),
          ),
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: Container(
            color: Colors.white,
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              labelPadding: const EdgeInsets.symmetric(horizontal: 18),
              indicatorColor: Colors.blue.shade700,
              indicatorWeight: 3,
              labelColor: Colors.blue.shade800,
              unselectedLabelColor: Colors.grey.shade600,
              labelStyle: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
              tabs: tabs.map((t) => Tab(text: t)).toList(),
            ),
          ),
        ),
      ),

      body: _loading
          ? _shimmerLoading()
          : TabBarView(
              controller: _tabController,
              children: List.generate(tabs.length, (index) {
                final items =
                    _itemsForTab(index).where((n) => !n.archived).toList()
                      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
                if (items.isEmpty) {
                  return _emptyState();
                }
                final grouped = _groupByDate(items);
                return RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      ...grouped.entries
                          .map(
                            (entry) => Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Text(
                                    entry.key,
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: Colors.grey.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                ...entry.value
                                    .map((n) => _dismissibleTile(n))
                                    .toList(),
                                const SizedBox(height: 12),
                              ],
                            ),
                          )
                          .toList(),
                      // Load More / Loading / No more — only on the
                      // "All" tab, since the other tabs are a
                      // client-side filter over whatever's already
                      // loaded, not their own separate paginated feed.
                      if (index == 0) _loadMoreFooter(),
                    ],
                  ),
                );
              }),
            ),
    );
  }

  // Dismissible with left/right actions
  Widget _dismissibleTile(AppNotification n) {
    return Dismissible(
      key: ValueKey(n.id),
      background: _swipeLeftBg(),
      secondaryBackground: _swipeRightBg(),
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          // swipe right -> archive (ask)
          final ok = await _confirmDialog("Archive notification?");
          if (ok) {
            await _service.archiveNotification(n.id);
            await _load();
          }
          return ok;
        } else {
          // swipe left -> delete
          final ok = await _confirmDialog("Delete notification permanently?");
          if (ok) {
            await _service.deleteNotification(n.id);
            await _load();
          }
          return ok;
        }
      },
      child: _notificationTile(n),
    );
  }

  Widget _notificationTile(AppNotification n) {
    return InkWell(
      onTap: () async {
        if (!n.read) {
          await _service.markRead(n.id);
          await _load();
        }
        // TODO: navigate to detail / booking / payment screen based on type
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // icon + unread dot
            Stack(
              clipBehavior: Clip.none,
              children: [
                Icon(
                  _iconForType(n.type),
                  size: 28,
                  color: Colors.blue.shade700,
                ),
                if (!n.read)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 9,
                      height: 9,
                      decoration: BoxDecoration(
                        color: Colors.blue.shade700,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    n.title,
                    style: TextStyle(
                      fontSize: 15.5,
                      fontWeight: n.read ? FontWeight.w600 : FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    n.message,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade700,
                      height: 1.45,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Text(
              _timeAgo(n.createdAt),
              style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
            ),
            PopupMenuButton<String>(
              onSelected: (val) async {
                if (val == 'mark_read') {
                  await _service.markRead(n.id);
                  await _load();
                } else if (val == 'mark_unread') {
                  await _service.markUnread(n.id);
                  await _load();
                } else if (val == 'archive') {
                  await _service.archiveNotification(n.id);
                  await _load();
                } else if (val == 'delete') {
                  final ok = await _confirmDialog(
                    "Delete notification permanently?",
                  );
                  if (ok) {
                    await _service.deleteNotification(n.id);
                    await _load();
                  }
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: n.read ? 'mark_unread' : 'mark_read',
                  child: Text(n.read ? 'Mark as unread' : 'Mark as read'),
                ),
                const PopupMenuItem(value: 'archive', child: Text('Archive')),
                const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _swipeLeftBg() {
    return Container(
      padding: const EdgeInsets.only(left: 20),
      color: Colors.red,
      alignment: Alignment.centerLeft,
      child: const Icon(Icons.delete, color: Colors.white),
    );
  }

  Widget _swipeRightBg() {
    return Container(
      padding: const EdgeInsets.only(right: 20),
      color: Colors.grey.shade700,
      alignment: Alignment.centerRight,
      child: const Icon(Icons.archive_outlined, color: Colors.white),
    );
  }

  Future<bool> _confirmDialog(String text) async {
    return await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Confirm'),
            content: Text(text),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes'),
              ),
            ],
          ),
        ) ??
        false;
  }

  Widget _loadMoreFooter() {
    if (_loadingMore) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 10),
              Text('Loading…', style: TextStyle(fontSize: 13)),
            ],
          ),
        ),
      );
    }
    if (!_service.hasMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text('No more notifications',
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: OutlinedButton(
          onPressed: _loadMore,
          child: const Text('Load More'),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.notifications_off_outlined,
              size: 76,
              color: Colors.grey.shade400,
            ),
            const SizedBox(height: 18),
            Text(
              "No notifications yet",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              "We'll notify you about bookings, payments and important system updates here.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade600),
            ),
            const SizedBox(height: 18),
            ElevatedButton(
              onPressed: _load,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue.shade700,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _shimmerLoading() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: 5,
      itemBuilder: (_, __) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Shimmer.fromColors(
            baseColor: Colors.grey.shade300,
            highlightColor: Colors.grey.shade100,
            child: Container(
              height: 72,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
        );
      },
    );
  }

  String _timeAgo(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return DateFormat.yMMMd().format(dt);
  }

  IconData _iconForType(NotificationType t) {
    switch (t) {
      case NotificationType.booking:
        return Icons.calendar_today_outlined;
      case NotificationType.payment:
        return Icons.payment_outlined;
      case NotificationType.chat:
        return Icons.chat_bubble_outline;
      case NotificationType.reminder:
        return Icons.notifications_active_outlined;
      case NotificationType.system:
        return Icons.info_outline;
      default:
        return Icons.notifications_none;
    }
  }
}
