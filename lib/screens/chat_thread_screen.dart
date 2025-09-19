// lib/screens/chat_thread_screen.dart
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/chat_service.dart';

class ChatThreadScreen extends StatefulWidget {
  final String chatId;

  // NEW: optional initial header values (passed from router)
  final String? initialTitle;
  final String? initialAvatarUrl;

  const ChatThreadScreen({
    super.key,
    required this.chatId,
    this.initialTitle,
    this.initialAvatarUrl,
  });

  @override
  State<ChatThreadScreen> createState() => _ChatThreadScreenState();
}

class _ChatThreadScreenState extends State<ChatThreadScreen> {
  final _chat = ChatService();

  final _scrollC = ScrollController();
  final _inputC = TextEditingController();

  List<Map<String, dynamic>> _msgs = [];
  StreamSubscription<Map<String, dynamic>>? _sub;
  bool _loading = true;
  String? _error;

  // Header state
  String _title = 'Chat';
  String? _avatarUrl;

  // debounce marking read so we don't spam updates
  Timer? _markReadDebounce;

  String get _uid => Supabase.instance.client.auth.currentUser?.id ?? '';

  @override
  void initState() {
    super.initState();

    // Use initial values immediately for snappy header
    _title = widget.initialTitle?.trim().isNotEmpty == true
        ? widget.initialTitle!.trim()
        : 'Chat';
    _avatarUrl = widget.initialAvatarUrl;

    _load();
    _maybeHydrateHeaderFromServer();

    _sub = _chat.subscribeMessages(widget.chatId).listen((m) {
      setState(() => _msgs.add(m));
      _scrollToBottom();
      if (m['sender_id'] != _uid) _markReadSoon();
    }, onError: (e) => debugPrint('[ChatThread] subscribe error: $e'));
  }

  // Only fetch profile if we didn't get a title via router (or to refresh it)
  Future<void> _maybeHydrateHeaderFromServer() async {
    if (widget.initialTitle != null && widget.initialTitle!.isNotEmpty) return;
    try {
      final other = await _chat.otherProfileForChat(widget.chatId);
      if (!mounted || other == null) return;
      final name = (other['display_name'] ?? other['email'] ?? '').toString();
      final avatar = (other['avatar_url'] ?? '').toString();
      if (name.isNotEmpty && mounted) {
        setState(() {
          _title = name;
          if (avatar.isNotEmpty) _avatarUrl = avatar;
        });
      }
    } catch (_) {
      // ignore; keep whatever we have
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _markReadDebounce?.cancel();
    _chat.markRead(widget.chatId).catchError((_) {});
    _scrollC.dispose();
    _inputC.dispose();
    super.dispose();
  }

  void _markReadSoon() {
    _markReadDebounce?.cancel();
    _markReadDebounce = Timer(const Duration(milliseconds: 350), () {
      _chat.markRead(widget.chatId).catchError((e) {
        debugPrint('[ChatThread] markRead error: $e');
      });
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await _chat.getMessages(widget.chatId, limit: 500);
      rows.sort((a, b) {
        final da = DateTime.tryParse('${a['created_at']}') ?? DateTime(1970);
        final db = DateTime.tryParse('${b['created_at']}') ?? DateTime(1970);
        return da.compareTo(db);
      });
      setState(() => _msgs = rows);
      _scrollToBottom(defer: true);
      _markReadSoon();
    } catch (e, st) {
      debugPrint('[ChatThread] load error: $e\n$st');
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _scrollToBottom({bool defer = false}) {
    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
      return;
    }
    if (!_scrollC.hasClients) return;
    _scrollC.animateTo(
      _scrollC.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Future<void> _send() async {
    final text = _inputC.text.trim();
    if (text.isEmpty) return;
    _inputC.clear();
    await _chat.sendMessage(widget.chatId, text);
    _scrollToBottom();
  }

  bool _isMine(Map<String, dynamic> m) => m['sender_id'] == _uid;

  Widget _centerTitle() {
    final title = _title.isEmpty ? 'Chat' : _title;
    final avatar = _avatarUrl;

    Widget leading;
    if (avatar != null && avatar.isNotEmpty) {
      leading = CircleAvatar(radius: 14, backgroundImage: NetworkImage(avatar));
    } else {
      final letter = title.isNotEmpty ? title[0].toUpperCase() : '?';
      leading = CircleAvatar(
        radius: 14,
        backgroundColor: const Color(0xFF0A84FF),
        child: Text(
          letter,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        leading,
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            color: Colors.black87,
            fontWeight: FontWeight.w700,
            fontSize: 18,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('HH:mm');

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(
          color: Colors.black87,
        ), // back chevron LEFT
        title: _centerTitle(),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Colors.redAccent),
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: ListView.builder(
                    controller: _scrollC,
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                    itemCount: _msgs.length,
                    itemBuilder: (context, i) {
                      final m = _msgs[i];
                      final mine = _isMine(m);
                      final time = df.format(
                        DateTime.tryParse('${m['created_at']}')?.toLocal() ??
                            DateTime.now(),
                      );
                      final text = (m['content'] ?? '').toString();

                      return LayoutBuilder(
                        builder: (context, constraints) {
                          final maxBubble = math.min(
                            constraints.maxWidth * 0.75,
                            520.0,
                          );
                          return Align(
                            alignment: mine
                                ? Alignment.centerRight
                                : Alignment.centerLeft,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(maxWidth: maxBubble),
                              child: Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  color: mine
                                      ? const Color(0xFF0A84FF) // iMessage blue
                                      : const Color(0xFFF2F3F7), // light gray
                                  borderRadius: BorderRadius.only(
                                    topLeft: const Radius.circular(18),
                                    topRight: const Radius.circular(18),
                                    bottomLeft: mine
                                        ? const Radius.circular(18)
                                        : const Radius.circular(6),
                                    bottomRight: mine
                                        ? const Radius.circular(6)
                                        : const Radius.circular(18),
                                  ),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      text,
                                      style: TextStyle(
                                        color: mine
                                            ? Colors.white
                                            : Colors.black87,
                                        fontSize: 16,
                                        height: 1.35,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Align(
                                      alignment: Alignment.bottomRight,
                                      child: Text(
                                        time,
                                        style: TextStyle(
                                          color: mine
                                              ? Colors.white70
                                              : Colors.black45,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),

                // Composer (light)
                SafeArea(
                  top: false,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      border: Border(
                        top: BorderSide(color: Color(0xFFE5E7EB)), // gray-200
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _inputC,
                            minLines: 1,
                            maxLines: 5,
                            decoration: InputDecoration(
                              hintText: 'iMessage',
                              filled: true,
                              fillColor: const Color(0xFFF2F3F7),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(18),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 12,
                              ),
                            ),
                            onSubmitted: (_) => _send(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Material(
                          color: const Color(0xFFE5E7EB),
                          shape: const CircleBorder(),
                          child: IconButton(
                            icon: const Icon(Icons.north_east_rounded),
                            onPressed: _send,
                            color: Colors.black54,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
