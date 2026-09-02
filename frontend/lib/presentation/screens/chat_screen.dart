// ─────────────────────────────────────────────
// presentation/screens/chat_screen.dart
//
// Chat tab: conversation list → thread view.
// Live via ChatApi (HTTP polling every 5s in a thread).
// ─────────────────────────────────────────────
import 'dart:async';
import 'package:flutter/material.dart';

import '../../core/api/chat_api.dart';
import '../../core/services/chat_badge_service.dart';
import '../../core/widgets/user_avatar.dart';
import '../../core/widgets/gms_header.dart';
import '../../core/services/session_manager.dart';
import '../../core/services/refresh_bus.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/time_format.dart';
import 'public_profile_screen.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  List<dynamic> _conversations = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
    RefreshBus.chat.addListener(_onRefreshBusChat);
  }

  void _onRefreshBusChat() {
    if (!mounted) return;
    _load();
  }

  @override
  void dispose() {
    RefreshBus.chat.removeListener(_onRefreshBusChat);
    super.dispose();
  }

  Future<void> _load() async {
    final res = await ChatApi.getConversations();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res.success && res.data is Map) {
        _conversations = res.data['conversations'] ?? [];
        _error = null;
      } else {
        _error = res.isOffline
            ? 'Unable to connect. Please check your connection and try again.'
            : res.message;
      }
    });

    // Keep the bottom-nav badge in sync with what's actually on screen —
    // reuses this same response, no extra API call.
    if (res.success && res.data is Map && res.data['conversations'] is List) {
      int count = 0;
      for (final raw in (res.data['conversations'] as List)) {
        final c = Map<String, dynamic>.from(raw as Map);
        final unread = int.tryParse('${c['unread_count'] ?? 0}') ?? 0;
        if (unread > 0) count++;
      }
      ChatBadgeService.unreadThreads.value = count;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        GMSHeader(parentContext: context), // showMenu defaults to false
        Expanded(
          child: RefreshIndicator(
            color: AppTheme.primaryBlue,
            onRefresh: _load,
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _messageState('⚠️', _error!)
                    : _conversations.isEmpty
                        ? _messageState('💬',
                            'No chats yet.\nBook a service and message your provider!')
                        : ListView.separated(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            itemCount: _conversations.length,
                            separatorBuilder: (_, __) => Divider(
                                height: 1,
                                indent: 76,
                                color: Colors.grey.shade100),
                            itemBuilder: (_, i) => _conversationTile(
                                Map<String, dynamic>.from(
                                    _conversations[i] as Map)),
                          ),
          ),
        ),
      ],
    );
  }

  Widget _messageState(String emoji, String text) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        const SizedBox(height: 120),
        Center(child: Text(emoji, style: const TextStyle(fontSize: 44))),
        const SizedBox(height: 12),
        Center(
          child: Text(text,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.black54)),
        ),
      ],
    );
  }

  Widget _conversationTile(Map<String, dynamic> c) {
    final name = (c['partner_name'] ?? '').toString();
    final last = (c['last_message'] ?? '').toString();
    final fromMe = c['last_from_me'] == 1 || c['last_from_me'] == true;
    final unread = int.tryParse('${c['unread_count'] ?? 0}') ?? 0;
    final partnerId = int.tryParse('${c['partner_id']}') ?? 0;
    final whenDt = parseServerTime('${c['last_message_at']}');
    final whenLabel = whenDt != null ? formatListTime(whenDt) : '';

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: GestureDetector(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => PublicProfileScreen(
                userId: partnerId,
                fallbackName: name,
                fallbackAvatar: (c['partner_avatar'] ?? '').toString()))),
        child: UserAvatar(
          name: name,
          avatarUrl: (c['partner_avatar'] ?? '').toString(),
          radius: 26,
        ),
      ),
      title: Text(name,
          style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15)),
      subtitle: Text(
        fromMe ? 'You: $last' : last,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
            fontSize: 13,
            color: unread > 0 ? Colors.black87 : Colors.black45,
            fontWeight: unread > 0 ? FontWeight.w600 : FontWeight.normal),
      ),
      trailing: SizedBox(
        width: 56,
        height: 56,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (whenLabel.isNotEmpty)
              Text(whenLabel,
                  style: TextStyle(
                      fontSize: 10.5,
                      color: unread > 0
                          ? AppTheme.primaryBlue
                          : Colors.black38,
                      fontWeight:
                          unread > 0 ? FontWeight.w600 : FontWeight.normal)),
            const SizedBox(height: 4),
            if (unread > 0)
              Container(
                padding: const EdgeInsets.all(5),
                constraints:
                    const BoxConstraints(minWidth: 20, minHeight: 20),
                decoration: const BoxDecoration(
                    color: AppTheme.primaryBlue, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text('$unread',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold)),
              ),
          ],
        ),
      ),
      onTap: () async {
        await Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => ChatThreadScreen(
                partnerId: partnerId,
                partnerName: name,
                partnerAvatar: (c['partner_avatar'] ?? '').toString())));
        _load(); // refresh unread counts on return
      },
    );
  }
}

// ═════════════════════════════════════════════
// THREAD VIEW
// ═════════════════════════════════════════════
class ChatThreadScreen extends StatefulWidget {
  final int partnerId;
  final String partnerName;
  final String? partnerAvatar;

  const ChatThreadScreen({
    super.key,
    required this.partnerId,
    required this.partnerName,
    this.partnerAvatar,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  Timer? _poll;

  List<dynamic> _messages = [];
  int? _myId;
  DateTime? _partnerLastSeen;
  String? _partnerAvatar;
  bool _loading = true;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _partnerAvatar = widget.partnerAvatar; // instant, no letter-flash
    _init();
    // lightweight live updates
    _poll = Timer.periodic(const Duration(seconds: 5), (_) => _fetch(silent: true));
  }

  Future<void> _init() async {
    final user = await SessionManager.getUser();
    _myId = int.tryParse('${user?['id']}');
    await _fetch();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetch({bool silent = false}) async {
    final res = await ChatApi.getThread(widget.partnerId);
    if (!mounted) return;
    if (res.success && res.data is Map) {
      final newMsgs = res.data['messages'] ?? [];
      final grew = newMsgs.length != _messages.length;
      final partner = res.data['partner'];
      setState(() {
        _messages = newMsgs;
        _loading = false;
        if (partner is Map) {
          _partnerLastSeen = parseServerTime('${partner['last_seen_at']}');
          _partnerAvatar = (partner['avatar_url'] ?? '').toString();
        }
      });
      if (grew) _jumpToBottom();
    } else if (!silent) {
      setState(() => _loading = false);
    }
  }

  void _jumpToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOut);
      }
    });
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    final res = await ChatApi.sendMessage(widget.partnerId, text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (res.success) {
      _msgCtrl.clear();
      await _fetch(silent: true);
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res.isOffline
              ? 'Message not sent — please check your connection.'
              : res.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FC),
      appBar: AppBar(
        title: GestureDetector(
          onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => PublicProfileScreen(
                  userId: widget.partnerId,
                  fallbackName: widget.partnerName,
                  fallbackAvatar: _partnerAvatar))),
          child: Row(
          children: [
            UserAvatar(
              name: widget.partnerName,
              avatarUrl: _partnerAvatar,
              radius: 16,
              backgroundColor: Colors.white,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.partnerName,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white)),
                  if (_partnerLastSeen != null)
                    Text(
                      formatRelativeAgo(_partnerLastSeen!) == 'Online now'
                          ? 'Online now'
                          : 'Last seen ${formatRelativeAgo(_partnerLastSeen!)}',
                      style: TextStyle(
                          fontSize: 11.5,
                          color:
                              formatRelativeAgo(_partnerLastSeen!) ==
                                      'Online now'
                                  ? Colors.greenAccent.shade100
                                  : Colors.white70),
                    ),
                ],
              ),
            ),
          ],
          ),
        ),
        centerTitle: false,
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView.builder(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.all(12),
                    itemCount: _timelineItems.length,
                    itemBuilder: (_, i) {
                      final item = _timelineItems[i];
                      if (item['_type'] == 'separator') {
                        return _daySeparator(item['label'] as String);
                      }
                      final isLastMine =
                          int.tryParse('${item['id']}') == _lastMineId;
                      return _bubble(item, showSeen: isLastMine);
                    },
                  ),
          ),
          _inputBar(),
        ],
      ),
    );
  }

  /// Messages + day-separator chips interleaved, in display order.
  List<Map<String, dynamic>> get _timelineItems {
    final items = <Map<String, dynamic>>[];
    DateTime? lastDay;
    for (final raw in _messages) {
      final m = Map<String, dynamic>.from(raw as Map);
      final dt = parseServerTime('${m['created_at']}');
      if (dt != null) {
        final day = DateTime(dt.year, dt.month, dt.day);
        if (lastDay == null || day != lastDay) {
          items.add({'_type': 'separator', 'label': formatDaySeparator(dt)});
          lastDay = day;
        }
      }
      items.add(m);
    }
    return items;
  }

  /// id of the most recent message I sent — only this bubble shows
  /// the "Seen" indicator, matching WhatsApp's single-checkmark-row UX.
  int? get _lastMineId {
    for (final raw in _messages.reversed) {
      final m = Map<String, dynamic>.from(raw as Map);
      if (int.tryParse('${m['sender_id']}') == _myId) {
        return int.tryParse('${m['id']}');
      }
    }
    return null;
  }

  Widget _daySeparator(String label) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(label,
            style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: AppTheme.primaryBlue)),
      ),
    );
  }

  Widget _bubble(Map<String, dynamic> m, {bool showSeen = false}) {
    final mine = int.tryParse('${m['sender_id']}') == _myId;
    final isRead = m['is_read'] == 1 || m['is_read'] == true;
    final isDelivered = parseServerTime('${m['delivered_at']}') != null;
    final readAt = parseServerTime('${m['read_at']}');

    return Column(
      crossAxisAlignment:
          mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Align(
          alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 3),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.75),
            decoration: BoxDecoration(
              color: mine ? AppTheme.primaryBlue : Colors.white,
              borderRadius: BorderRadius.only(
                topLeft: const Radius.circular(16),
                topRight: const Radius.circular(16),
                bottomLeft: Radius.circular(mine ? 16 : 4),
                bottomRight: Radius.circular(mine ? 4 : 16),
              ),
              boxShadow: [
                BoxShadow(
                    color: Colors.black.withOpacity(0.04),
                    blurRadius: 4,
                    offset: const Offset(0, 1)),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  (m['body'] ?? '').toString(),
                  style: TextStyle(
                      color: mine ? Colors.white : Colors.black87,
                      fontSize: 14.5,
                      height: 1.3),
                ),
                const SizedBox(height: 3),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _bubbleTime(m),
                      style: TextStyle(
                          fontSize: 10.5,
                          color: mine ? Colors.white70 : Colors.black38),
                    ),
                    if (mine) ...[
                      const SizedBox(width: 3),
                      Icon(
                        // Single tick: sent, recipient's device
                        // hasn't confirmed receipt yet. Double tick
                        // (grey): delivered — their app is online
                        // and has it, but they haven't opened this
                        // thread. Double tick (blue): read.
                        isRead || isDelivered
                            ? Icons.done_all
                            : Icons.done,
                        size: 13,
                        color: isRead
                            ? Colors.lightBlueAccent.shade100
                            : Colors.white70,
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        // "Seen X ago" — only under the single most recent message I
        // sent, once the other person has actually read it.
        if (showSeen && mine && isRead && readAt != null)
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 6, top: 1),
            child: Text('Seen ${formatRelativeAgo(readAt)}',
                style: const TextStyle(
                    fontSize: 10.5, color: Colors.black38)),
          ),
      ],
    );
  }

  String _bubbleTime(Map<String, dynamic> m) {
    final dt = parseServerTime('${m['created_at']}');
    return dt != null ? formatClockTime(dt) : '';
  }

  Widget _inputBar() {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        color: Colors.white,
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _msgCtrl,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Type a message…',
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onSubmitted: (_) => _send(),
              ),
            ),
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 23,
              backgroundColor: AppTheme.primaryBlue,
              child: _sending
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : IconButton(
                      icon: const Icon(Icons.send_rounded,
                          color: Colors.white, size: 20),
                      onPressed: _send,
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
