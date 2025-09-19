// lib/screens/chat_list_screen.dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/chat_service.dart';

class ChatListScreen extends StatefulWidget {
  final List<Map<String, dynamic>> managedFromRoute;
  const ChatListScreen({super.key, this.managedFromRoute = const []});

  @override
  State<ChatListScreen> createState() => _ChatListScreenState();
}

class _ChatListScreenState extends State<ChatListScreen> {
  // ---- Services ----
  final _chat = ChatService();
  final _db = Supabase.instance.client;

  // ---- State ----
  bool loading = true;
  String? error;

  List<_InboxRow> items = [];
  List<_InboxRow> _filtered = [];
  List<Map<String, dynamic>> managed = [];
  Map<String, int> unread = {};

  Timer? _refreshTimer;
  String get _uid => _db.auth.currentUser?.id ?? '';

  // Search
  final _searchC = TextEditingController();
  String _q = '';

  // ---- Theme (light / iOS-ish) ----
  static const _bg = Colors.white;
  static const _brand = Color(0xFF6C63FF);
  static const _titleColor = Color(0xFF111827); // gray-900
  static const _subtitleColor = Color(0xFF6B7280); // gray-500
  static const _divider = Color(0xFFE5E7EB); // gray-200
  static const _chip = Color(0xFFF3F4F6); // gray-100

  // Bottom bar / FAB tuning (match Manager page)
  static const double kFabDiameter = 52;
  static const double kFabYOffset = 30;
  static const double kFabGapWidth = 80;
  static const double kBarHeight = 64;

  @override
  void initState() {
    super.initState();
    managed = widget.managedFromRoute;
    _load();
    _refreshTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _loadUnreadOnly(),
    );
    _searchC.addListener(() {
      setState(() {
        _q = _searchC.text;
        _applyFilter();
      });
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _searchC.dispose();
    super.dispose();
  }

  // ---------- loading ----------

  Future<void> _loadUnreadOnly() async {
    try {
      final m = await _chat.unreadCounts();
      if (mounted) setState(() => unread = m);
    } catch (_) {}
  }

  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });

    try {
      // 1) my chats
      final chats = await _chat
          .listChats(); // id,is_group,title,pair_key,last_message_at
      if (chats.isEmpty) {
        setState(() {
          items = [];
          _filtered = [];
          unread = {};
        });
        return;
      }

      final chatIds = chats.map((c) => c['id'] as String).toList();

      // 2) other user for DMs (from pair_key)
      final otherIdByChat = <String, String>{};
      final otherIds = <String>[];
      for (final c in chats) {
        final cid = c['id'] as String;
        final isGroup = (c['is_group'] == true);
        if (isGroup) continue;
        final pk = (c['pair_key'] ?? '').toString();
        final parts = pk.split(':');
        if (parts.length == 2) {
          String? other;
          if (parts[0] == _uid) {
            other = parts[1];
          } else if (parts[1] == _uid) {
            other = parts[0];
          }
          if (other != null && other.isNotEmpty) {
            otherIdByChat[cid] = other;
            otherIds.add(other);
          }
        }
      }

      // 3) load those profiles — include avatar_url
      final profileById = <String, Map<String, dynamic>>{};
      if (otherIds.isNotEmpty) {
        final profs = await _db
            .from('profiles')
            .select('id,display_name,email,avatar_url')
            .inFilter('id', otherIds.toSet().toList());
        for (final p in (profs as List)) {
          final map = Map<String, dynamic>.from(p as Map);
          profileById[map['id'] as String] = map;
        }
      }

      // 4) latest message per chat
      final msgs = await _db
          .from('im_messages')
          .select('chat_id,content,created_at')
          .inFilter('chat_id', chatIds)
          .order('created_at', ascending: false);

      final latestByChat = <String, Map<String, dynamic>>{};
      for (final r in (msgs as List)) {
        final m = Map<String, dynamic>.from(r as Map);
        final cid = m['chat_id'] as String;
        latestByChat.putIfAbsent(cid, () => m); // first = newest
      }

      // 5) unread map
      final unreadMap = await _chat.unreadCounts();

      // 6) build rows
      final rows = <_InboxRow>[];
      for (final c in chats) {
        final cid = c['id'] as String;
        final isGroup = (c['is_group'] == true);
        final lastAt = DateTime.tryParse('${c['last_message_at'] ?? ''}');

        String title;
        String? avatar;
        if (isGroup) {
          title = (c['title'] ?? 'Group').toString();
          avatar = null;
        } else {
          final other = profileById[otherIdByChat[cid] ?? ''];
          final dn = (other?['display_name'] as String?)?.trim();
          final em = (other?['email'] as String?)?.trim();
          title = (dn != null && dn.isNotEmpty) ? dn : (em ?? 'Chat');
          avatar = (other?['avatar_url'] as String?)?.trim();
        }

        final last = latestByChat[cid];
        final preview = (last?['content'] ?? '') as String? ?? '';
        final lastTime =
            DateTime.tryParse('${last?['created_at'] ?? ''}') ?? lastAt;

        rows.add(
          _InboxRow(
            chatId: cid,
            title: title,
            preview: preview.isEmpty ? 'No messages yet' : preview,
            lastAt: lastTime,
            unread: unreadMap[cid] ?? 0,
            avatarUrl: avatar,
          ),
        );
      }

      rows.sort((a, b) {
        final da = a.lastAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final db = b.lastAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return db.compareTo(da);
      });

      if (!mounted) return;
      setState(() {
        items = rows;
        unread = unreadMap;
        _applyFilter();
      });
    } catch (e, st) {
      debugPrint('[ChatList] load error: $e\n$st');
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  void _applyFilter() {
    final q = _q.trim().toLowerCase();
    if (q.isEmpty) {
      _filtered = List<_InboxRow>.from(items);
    } else {
      _filtered = items.where((r) {
        return r.title.toLowerCase().contains(q) ||
            r.preview.toLowerCase().contains(q);
      }).toList();
    }
  }

  // ---------- new chat sheet (light) ----------

  void _openNewChatSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        var filtered = List<Map<String, dynamic>>.from(managed);
        final tc = TextEditingController();

        void applyFilter(String q) {
          final qq = q.trim().toLowerCase();
          filtered = managed.where((m) {
            final p =
                (m['artist_profile'] as Map<String, dynamic>?) ??
                (m['manager_profile'] as Map<String, dynamic>?) ??
                m;
            final name = (p['display_name'] ?? '').toString().toLowerCase();
            final email = (p['email'] ?? '').toString().toLowerCase();
            final code = (p['unique_code'] ?? '').toString().toLowerCase();
            return qq.isEmpty ||
                name.contains(qq) ||
                email.contains(qq) ||
                code.contains(qq);
          }).toList();
        }

        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 16,
                bottom: MediaQuery.of(sheetCtx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Center(
                    child: Text(
                      'Start a new chat',
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: tc,
                    onChanged: (v) => setSheetState(() => applyFilter(v)),
                    decoration: InputDecoration(
                      hintText: 'Search managed contacts',
                      filled: true,
                      fillColor: _chip,
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (managed.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No managed users yet.'),
                    )
                  else
                    SizedBox(
                      height: 420,
                      child: filtered.isEmpty
                          ? const Center(child: Text('No matches'))
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => const Divider(
                                height: 0,
                                thickness: 0.6,
                                color: _divider,
                                indent: 72,
                              ),
                              itemBuilder: (_, i) {
                                final row = filtered[i];
                                final p =
                                    (row['artist_profile']
                                        as Map<String, dynamic>?) ??
                                    (row['manager_profile']
                                        as Map<String, dynamic>?) ??
                                    row;
                                final title =
                                    (p['display_name'] ?? p['email'] ?? 'User')
                                        .toString();
                                return ListTile(
                                  leading: _avatar(title),
                                  title: Text(
                                    title,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  subtitle: Text((p['email'] ?? '').toString()),
                                  onTap: () async {
                                    Navigator.pop(sheetCtx);
                                    await _startChatWith(row);
                                  },
                                );
                              },
                            ),
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------- actions ----------

  Future<void> _startChatWith(Map<String, dynamic> item) async {
    try {
      final profile =
          (item['artist_profile'] as Map<String, dynamic>?) ??
          (item['manager_profile'] as Map<String, dynamic>?) ??
          item;

      String? otherId;
      for (final k in [
        'artist_id',
        'manager_id',
        'user_id',
        'id',
        'uid',
        'profile_id',
      ]) {
        final v = item[k] ?? profile[k];
        if (v != null && v.toString().isNotEmpty) {
          otherId = v.toString();
          break;
        }
      }

      if (otherId == null) {
        final email = (profile['email'] ?? item['email'])?.toString();
        if (email != null && email.isNotEmpty) {
          final row = await _db
              .from('profiles')
              .select('id')
              .eq('email', email)
              .maybeSingle();
          if (row != null && row['id'] != null) otherId = row['id'] as String;
        }
      }

      if (otherId == null) {
        _snack('Could not find user id to chat with');
        return;
      }

      final chatId = await _chat.getOrCreateDirectChatWith(otherId);
      if (!mounted) return;
      await context.push('/chats/$chatId');
      await _load(); // refresh after returning
    } catch (e) {
      _snack('Error: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------- UI helpers ----------

  Widget _avatar(String nameOrEmail) {
    final t = nameOrEmail.trim();
    final letter = (t.isNotEmpty ? t[0] : '?').toUpperCase();
    return CircleAvatar(
      radius: 24,
      backgroundColor: _brand,
      child: Text(
        letter,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  String _formatTime(DateTime? dt) {
    if (dt == null) return '';
    final now = DateTime.now();
    final d = dt.toLocal();
    final sameDay =
        d.year == now.year && d.month == now.month && d.day == now.day;
    if (sameDay) return DateFormat('HH:mm').format(d);
    return DateFormat('dd/MM/yy').format(d);
  }

  void _openScanner() {
    // hook into your existing scanner action if you want
    // Navigator / callback
  }

  void _onTapHome() => context.pop(); // or scroll to top if you prefer

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        elevation: 0,
        foregroundColor: _titleColor,
        title: const Text(
          'Chats',
          style: TextStyle(color: _titleColor, fontWeight: FontWeight.w800),
        ),
        centerTitle: false,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
            color: _titleColor,
          ),
          IconButton(
            tooltip: 'New chat',
            onPressed: _openNewChatSheet,
            icon: const Icon(Icons.chat_bubble_outline),
            color: _titleColor,
          ),
        ],
      ),

      // Center docked FAB (same style as Manager)
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Transform.translate(
        offset: const Offset(0, kFabYOffset),
        child: SizedBox(
          width: kFabDiameter,
          height: kFabDiameter,
          child: FloatingActionButton(
            heroTag: 'chatFab',
            backgroundColor: const Color.fromRGBO(44, 60, 96, 1),
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            onPressed: _openNewChatSheet,
            child: const Icon(Icons.add, size: 28),
          ),
        ),
      ),

      // Bottom app bar copied from Manager (with Home / Scanner / Settings)
      bottomNavigationBar: BottomAppBar(
        shape: const CircularNotchedRectangle(),
        notchMargin: 6,
        elevation: 10,
        color: Colors.white,
        child: SizedBox(
          height: kBarHeight,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Left side
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: Row(
                  children: [
                    _BottomItem(
                      icon: Icons.home_rounded,
                      label: 'Home',
                      onTap: _onTapHome,
                    ),
                    const SizedBox(width: 28),
                    _BottomItem(
                      icon: Icons.description_outlined,
                      label: 'Scanner',
                      onTap: _openScanner,
                    ),
                  ],
                ),
              ),
              // gap for FAB
              const SizedBox(width: kFabGapWidth),
              // Right side
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(
                  children: [
                    _BottomItem(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      onTap: () {
                        // TODO: settings route
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),

      body: loading
          ? const Center(child: CircularProgressIndicator())
          : error != null
          ? Center(
              child: Text(
                error!,
                style: const TextStyle(color: Colors.redAccent),
              ),
            )
          : Column(
              children: [
                // Search
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: TextField(
                    controller: _searchC,
                    decoration: InputDecoration(
                      hintText: 'Search',
                      filled: true,
                      fillColor: _chip,
                      prefixIcon: const Icon(Icons.search),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 12,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: _filtered.isEmpty
                      ? const Center(child: Text('No chats yet'))
                      : RefreshIndicator(
                          onRefresh: _load,
                          child: ListView.separated(
                            padding: const EdgeInsets.only(bottom: 100),
                            itemCount: _filtered.length,
                            // divider + spacer
                            separatorBuilder: (_, __) => Column(
                              children: const [
                                Divider(
                                  height: 0,
                                  thickness: 0.6,
                                  color: _divider,
                                  indent: 72,
                                ),
                                SizedBox(height: 6),
                              ],
                            ),
                            itemBuilder: (_, i) {
                              final row = _filtered[i];
                              final count = unread[row.chatId] ?? row.unread;

                              final titleStyle = TextStyle(
                                color: _titleColor,
                                fontWeight: count > 0
                                    ? FontWeight.w700
                                    : FontWeight.w600,
                                fontSize: 16,
                                height: 1.25,
                              );

                              return InkWell(
                                onTap: () async {
                                  await context.push(
                                    '/chats/${row.chatId}',
                                    extra: {
                                      'initialTitle': row.title,
                                      'initialAvatarUrl': row.avatarUrl ?? '',
                                    },
                                  );
                                  await _load();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                  child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      (row.avatarUrl != null &&
                                              row.avatarUrl!.isNotEmpty)
                                          ? CircleAvatar(
                                              radius: 24,
                                              backgroundImage: NetworkImage(
                                                row.avatarUrl!,
                                              ),
                                            )
                                          : _avatar(row.title),
                                      const SizedBox(width: 14),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    row.title,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: titleStyle,
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Text(
                                                  _formatTime(row.lastAt),
                                                  style: const TextStyle(
                                                    color: _subtitleColor,
                                                    fontSize: 12,
                                                    height: 1.2,
                                                  ),
                                                ),
                                              ],
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.center,
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    row.preview,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: const TextStyle(
                                                      color: _subtitleColor,
                                                      fontSize: 15,
                                                      height: 1.35,
                                                    ),
                                                  ),
                                                ),
                                                if (count > 0) ...[
                                                  const SizedBox(width: 10),
                                                  Container(
                                                    padding:
                                                        const EdgeInsets.symmetric(
                                                          horizontal: 8,
                                                          vertical: 3,
                                                        ),
                                                    decoration: BoxDecoration(
                                                      color: _brand,
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            999,
                                                          ),
                                                    ),
                                                    child: Text(
                                                      count > 99
                                                          ? '99+'
                                                          : '$count',
                                                      style: const TextStyle(
                                                        color: Colors.white,
                                                        fontSize: 12,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                ),
              ],
            ),
    );
  }
}

class _InboxRow {
  final String chatId;
  final String title;
  final String preview;
  final DateTime? lastAt;
  final int unread;
  final String? avatarUrl; // NEW

  _InboxRow({
    required this.chatId,
    required this.title,
    required this.preview,
    required this.lastAt,
    required this.unread,
    this.avatarUrl,
  });
}

// ---- Small labeled bottom bar item (copied from Manager) ----
class _BottomItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  final double iconSize;
  final double labelSize;

  const _BottomItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.iconSize = 27,
    this.labelSize = 9,
  });

  @override
  Widget build(BuildContext context) {
    final sel = const Color.fromARGB(240, 103, 96, 237);
    final iconColor = selected ? sel : const Color.fromARGB(233, 159, 157, 157);
    final textColor = selected ? sel : const Color.fromARGB(233, 161, 159, 159);

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: iconSize, color: iconColor),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: labelSize,
                fontWeight: FontWeight.w600,
                color: textColor,
                letterSpacing: 0.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
