// lib/services/chat_service.dart
//
// Messaging service with deterministic pair_key (prevents duplicate 1:1 threads)
// + per-user read markers (last_read_at) for unread badges.
//
// ONE-TIME SQL you should run in Supabase:
//
//   -- pair_key to dedupe direct chats
//   alter table public.chats
//     add column if not exists pair_key text;
//   create unique index if not exists chats_pair_key_unique
//     on public.chats (pair_key) where is_group = false;
//
//   -- read markers on membership
//   alter table public.chat_members
//     add column if not exists last_read_at timestamptz;
//
//   -- allow member to update their own last_read_at
//   drop policy if exists chat_members_update_self on public.chat_members;
//   create policy chat_members_update_self
//   on public.chat_members for update
//   to authenticated
//   using (user_id = auth.uid())
//   with check (user_id = auth.uid());
//
// Assumes you already have insert policies that allow a creator to insert into
// chats (created_by = auth.uid()) and add chat_members for the chat they just created.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


class ChatService {
  final SupabaseClient _db = Supabase.instance.client;

  static const _tChats = 'chats';
  static const _tChatMembers = 'chat_members';
  static const _tMessages = 'im_messages';

  String get _uid {
    final u = _db.auth.currentUser;
    if (u == null) {
      debugPrint('[ChatService] ERROR: not signed in.');
      throw StateError('Not signed in');
    }
    return u.id;
  }

  // ---------- Helpers ----------

  /// Build a deterministic key for a direct chat (sorted "a:b").
  String _pairKeyFor(String a, String b) {
    return (a.compareTo(b) < 0) ? '$a:$b' : '$b:$a';
  }

  /// For a 1:1 chat, return the *other* participant's profile {id, display_name, email}.
  Future<Map<String, dynamic>?> otherProfileForChat(String chatId) async {
    final me = _db.auth.currentUser?.id;
    if (me == null) return null;

    final members = await _db
        .from(_tChatMembers)
        .select('user_id')
        .eq('chat_id', chatId);

    final others = (members as List)
        .map((e) => (e as Map)['user_id'] as String)
        .where((id) => id != me)
        .toList();

    if (others.isEmpty) return null;

    final prof = await _db
        .from('profiles')
        .select('id,display_name,email')
        .eq('id', others.first)
        .maybeSingle();

    if (prof == null) return null;
    return Map<String, dynamic>.from(prof as Map);
  }

  // ---------- Chats ----------

  /// All chats the current user is in (newest first).
  Future<List<Map<String, dynamic>>> listChats() async {
    final uid = _db.auth.currentUser?.id;
    debugPrint('[ChatService] listChats() as uid=$uid');

    final mems = await _db
        .from(_tChatMembers)
        .select('chat_id')
        .eq('user_id', _uid);

    if (mems is! List || mems.isEmpty) {
      debugPrint('[ChatService] listChats -> 0 (no memberships)');
      return [];
    }

    final chatIds = mems.map((e) => (e as Map)['chat_id'] as String).toList();

    final rows = await _db
        .from(_tChats)
        .select(
          'id,is_group,title,pair_key,last_message_at,created_by,created_at',
        )
        .inFilter('id', chatIds)
        .order('last_message_at', ascending: false);

    final list = (rows as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    debugPrint('[ChatService] listChats loaded=${list.length}');
    return list;
  }

  /// Find or create a direct (1:1) chat using a stable pair_key to avoid duplicates.
  Future<String> getOrCreateDirectChatWith(String otherUserId) async {
    final me = _uid;
    final pairKey = _pairKeyFor(me, otherUserId);
    debugPrint(
      '[ChatService] getOrCreateDirectChatWith me=$me other=$otherUserId pairKey=$pairKey',
    );

    // 1) Try to find existing direct chat by pair_key
    try {
      final existing = await _db
          .from(_tChats)
          .select('id')
          .eq('is_group', false)
          .eq('pair_key', pairKey)
          .maybeSingle();

      if (existing != null && existing is Map && existing['id'] != null) {
        final id = existing['id'] as String;
        debugPrint('[ChatService] found existing chat id=$id');
        return id;
      }
    } catch (e) {
      debugPrint('[ChatService] lookup by pair_key error: $e');
      // fall through to create
    }

    // 2) Create chat with that pair_key (unique index prevents dupes on races)
    try {
      final chat = await _db
          .from(_tChats)
          .insert({
            'is_group': false,
            'created_by': me, // satisfies your RLS insert policy
            'pair_key': pairKey,
          })
          .select('id')
          .single();

      final chatId = chat['id'] as String;

      // Add both members
      await _db.from(_tChatMembers).insert({'chat_id': chatId, 'user_id': me});
      await _db.from(_tChatMembers).insert({
        'chat_id': chatId,
        'user_id': otherUserId,
      });

      debugPrint('[ChatService] created chat id=$chatId');
      return chatId;
    } on PostgrestException catch (e) {
      // 23505 = unique violation (two clients tried to create simultaneously)
      if (e.code == '23505') {
        debugPrint(
          '[ChatService] unique violation (race). Fetching existing chat by pair_key.',
        );
        final existing = await _db
            .from(_tChats)
            .select('id')
            .eq('is_group', false)
            .eq('pair_key', pairKey)
            .single();
        return existing['id'] as String;
      }
      debugPrint(
        '[ChatService] create chat error: ${e.message} code=${e.code}',
      );
      rethrow;
    }
  }

  // ---------- Messages ----------

  /// Initial page of messages (oldest → newest).
  Future<List<Map<String, dynamic>>> getMessages(
    String chatId, {
    int limit = 100,
  }) async {
    debugPrint('[ChatService] getMessages($chatId, limit=$limit)');
    final rows = await _db
        .from(_tMessages)
        .select('id,chat_id,sender_id,content,type,created_at')
        .eq('chat_id', chatId)
        .order('created_at')
        .limit(limit);

    final list = (rows as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    debugPrint('[ChatService] messages loaded=${list.length}');
    return list;
  }

  /// Realtime: new messages for this chat (insert events).
  Stream<Map<String, dynamic>> subscribeMessages(String chatId) {
    debugPrint('[ChatService] subscribeMessages($chatId)');
    final controller = StreamController<Map<String, dynamic>>.broadcast();

    final channel = _db.channel('im_messages-$chatId');

    channel.onPostgresChanges(
      event: PostgresChangeEvent.insert,
      schema: 'public',
      table: _tMessages,
      // ✅ Typed filter (newer SDKs require PostgresChangeFilter)
      filter: PostgresChangeFilter(
        type: PostgresChangeFilterType.eq,
        column: 'chat_id',
        value: chatId,
      ),
      callback: (payload) {
        final row = payload.newRecord;
        if (row is Map) {
          final m = Map<String, dynamic>.from(row);
          debugPrint('[ChatService] realtime insert => $m');
          controller.add(m);
        }
      },
    );

    channel.subscribe();
    controller.onCancel = () => _db.removeChannel(channel);
    return controller.stream;
  }

  /// Send a text message and bump chat's last_message_at.
  Future<void> sendMessage(String chatId, String content) async {
    final text = content.trim();
    if (text.isEmpty) return;

    final now = DateTime.now().toUtc().toIso8601String();
    debugPrint(
      '[ChatService] sendMessage chat=$chatId from=$_uid text="$text"',
    );

    await _db.from(_tMessages).insert({
      'chat_id': chatId,
      'sender_id': _uid,
      'content': text,
      'type': 'text',
    });

    await _db.from(_tChats).update({'last_message_at': now}).eq('id', chatId);
  }

  // ---------- Read markers & unread counts ----------

  /// Mark this chat as read now for the current user.
  Future<void> markRead(String chatId) async {
    final now = DateTime.now().toUtc().toIso8601String();
    debugPrint('[ChatService] markRead chat=$chatId now=$now');
    await _db
        .from(_tChatMembers)
        .update({'last_read_at': now})
        .eq('chat_id', chatId)
        .eq('user_id', _uid);
  }

  /// Per-chat unread counts for the current user, based on last_read_at.
  /// Counts messages newer than last_read_at and not sent by me.
  Future<Map<String, int>> unreadCounts() async {
    final uid = _uid;
    final mems = await _db
        .from(_tChatMembers)
        .select('chat_id,last_read_at')
        .eq('user_id', uid);

    if (mems is! List || mems.isEmpty) return {};

    final Map<String, int> out = {};
    for (final m in mems) {
      final map = Map<String, dynamic>.from(m as Map);
      final chatId = (map['chat_id'] ?? '').toString();
      if (chatId.isEmpty) continue;

      final last =
          DateTime.tryParse(
            (map['last_read_at'] ?? '1970-01-01T00:00:00Z').toString(),
          ) ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

      final rows = await _db
          .from(_tMessages)
          .select('id,sender_id,created_at')
          .eq('chat_id', chatId)
          .gt('created_at', last.toUtc().toIso8601String());

      final list = (rows as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((e) => (e['sender_id'] ?? '') != uid)
          .toList();

      out[chatId] = list.length;
      debugPrint(
        '[ChatService] unread chat=$chatId since=$last -> ${list.length}',
      );
    }
    return out;
  }

  /// Convenience: total unread across all chats (for the dashboard badge).
  Future<int> unreadTotal() async {
    final m = await unreadCounts();
    var total = 0;
    for (final v in m.values) {
      if (v is int) total += v;
    }
    return total;
  }
}
