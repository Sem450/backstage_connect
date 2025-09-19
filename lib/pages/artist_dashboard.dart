// lib/screens/artist_dashboard.dart
import 'dart:async';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../widgets/todo_panel.dart';
import '../widgets/risk_face.dart';
import '../models/app_user.dart';
import '../models/uploaded_contract.dart';
import '../services/auth_service.dart';
import '../services/chat_service.dart';
import '../services/contract_service.dart';
import 'saved_analyses_page.dart';
import '../utils/errors.dart';

class ArtistDashboard extends StatefulWidget {
  const ArtistDashboard({super.key});
  @override
  State<ArtistDashboard> createState() => _ArtistDashboardState();
}

// ---- Small avatar helper (shared look with Manager)
Widget _avatar({required String label, String? avatarUrl, double size = 40}) {
  final ch = label.isNotEmpty ? label.trim()[0].toUpperCase() : 'U';

  if (avatarUrl != null && avatarUrl.trim().isNotEmpty) {
    return ClipOval(
      child: Image.network(
        avatarUrl,
        key: ValueKey(avatarUrl),
        width: size,
        height: size,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => CircleAvatar(
          radius: size / 2,
          backgroundColor: const Color(0xFF6C63FF),
          child: Text(ch, style: const TextStyle(color: Colors.white)),
        ),
      ),
    );
  }

  return CircleAvatar(
    radius: size / 2,
    backgroundColor: const Color(0xFF6C63FF),
    child: Text(ch, style: const TextStyle(color: Colors.white)),
  );
}

class _ArtistDashboardState extends State<ArtistDashboard> {
  // ---- Layout knobs (mirrors Manager)
  static const double kHeaderHeight = 190;
  static const double kHeaderTopExtra = 6;
  static const double kManagedOverlap = 120;
  static const double kCardRowHeight = 170;
  static const double kCardWidth = 260;

  static const double kAfterHeaderGap = 28;
  static const double kLabelToCardsGap = 12;

  static const double kGreetingTopPadding = 8;
  static const double kManagerAvatarSize = 60;

  static const double kFabDiameter = 52;
  static const double kFabYOffset = 30;
  static const double kFabGapWidth = 80;
  static const double kBarHeight = 64;

  static const _accent = Color(0xFF6C63FF);

  final _auth = AuthService();
  final _chat = ChatService();
  final _contracts = ContractService();

  final _pageScrollC = ScrollController();

  AppUser? me;

  // Managers the artist has accepted
  List<Map<String, dynamic>> myManagers = [];

  // Pending incoming requests (from managers)
  List<Map<String, dynamic>> pending = [];

  // For To-Do assignee options (self + managers)
  List<Map<String, dynamic>> managedRowsForArtist = [];

  // unread badge
  int _unreadTotal = 0;
  Timer? _badgeTimer;

  // ------- Scanner state -------
  final ValueNotifier<String> _scanStatus = ValueNotifier<String>('Starting…');
  UploadedContract? _lastUpload;

  bool loading = true;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
    _badgeTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshUnread(),
    );
  }

  @override
  void dispose() {
    _badgeTimer?.cancel();
    _pageScrollC.dispose();
    super.dispose();
  }

  // ---------- Data ----------
  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      me = await _auth.currentProfile();
      myManagers = await _auth.myManagers();
      pending = await _auth.pendingRequestsForArtist();

      // Build To-Do assignee list: self + managers
      managedRowsForArtist = [
        {
          'id': me?.id ?? '',
          'display_name': me?.displayName ?? (me?.email ?? 'Me'),
          'email': me?.email ?? '',
          'avatar_url': me?.avatarUrl ?? '',
        },
        ...myManagers.map((row) {
          final p = (row['manager_profile'] as Map<String, dynamic>?) ?? row;
          return {
            'id': (p['id'] ?? row['manager_id'] ?? '').toString(),
            'display_name': (p['display_name'] ?? p['email'] ?? 'Manager')
                .toString(),
            'email': (p['email'] ?? '').toString(),
            'avatar_url': (p['avatar_url'] ?? '').toString(),
          };
        }),
      ];

      await _refreshUnread();
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> _refreshUnread() async {
    try {
      final n = await _chat.unreadTotal();
      if (mounted) setState(() => _unreadTotal = n);
    } catch (_) {
      if (mounted) setState(() => _unreadTotal = 0);
    }
  }

  // ---------- CALL YOUR EDGE FUNCTION (manual, if you want to pass a URL directly) ----------
  Future<void> analyzeContract(String presignedFileUrl) async {
    final userId =
        Supabase.instance.client.auth.currentUser?.id ?? 'guest'; // 👈 user id

    final res = await Supabase.instance.client.functions.invoke(
      'analyze-contract', // Edge Function name
      body: {'fileUrl': presignedFileUrl},
      headers: {'X-User-Id': userId}, // 👈 per-user limit header
    );

    if (!mounted) return;
    if (res.status == 200) {
      _snack('Analysis complete.');
      // Optionally inspect res.data
    } else {
      _snack('Error: ${res.status} ${res.data}');
    }
  }

  // ---------- Contract upload + scan (like Manager) ----------
  Future<void> _uploadAndScan() async {
    VoidCallback? dismiss;
    try {
      _scanStatus.value = 'Preparing…';
      dismiss = _presentScanningOverlay();

      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt'],
        withData: true,
      );
      if (picked == null) {
        dismiss();
        return;
      }

      _scanStatus.value = 'Uploading file…';
      final f = picked.files.single;

      String signedUrl;
      if (f.bytes != null) {
        signedUrl = await _contracts.uploadContract(
          bytes: f.bytes!,
          originalName: f.name,
        );
      } else if (f.path != null) {
        signedUrl = await _contracts.uploadContract(
          file: File(f.path!),
          originalName: f.name,
        );
      } else {
        dismiss();
        _snack('No file path returned.');
        return;
      }

      _lastUpload = UploadedContract(fileUrl: signedUrl, originalName: f.name);

      _scanStatus.value = 'Analyzing with AI…';
      final result = await _contracts.analyzeByUrl(signedUrl);

      _scanStatus.value = 'Finishing up…';
      await Future.delayed(const Duration(milliseconds: 250));

      dismiss();
      _showAnalysisDialogNew(result);
    } catch (e) {
      if (dismiss != null) dismiss();
      _snack('Error: $e');
    }
  }

  // ---------- Overlay ----------
  VoidCallback _presentScanningOverlay() {
    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: true,
      builder: (_) => Dialog(
        backgroundColor: Colors.white,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 72,
                height: 72,
                child: Stack(
                  alignment: Alignment.center,
                  children: const [
                    CircularProgressIndicator(
                      strokeWidth: 6,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Color(0xFF6C63FF),
                      ),
                      backgroundColor: Colors.black12,
                    ),
                    Icon(
                      Icons.description_outlined,
                      size: 26,
                      color: Color(0xFF6C63FF),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Scanning your contract…',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16),
              ),
              const SizedBox(height: 6),
              ValueListenableBuilder<String>(
                valueListenable: _scanStatus,
                builder: (_, status, __) => Text(
                  status,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    return () {
      if (Navigator.of(context, rootNavigator: true).canPop()) {
        Navigator.of(context, rootNavigator: true).pop();
      }
    };
  }

  // ---------- UI helpers/actions ----------
  String _displayName(Map<String, dynamic> p) {
    final dn = (p['display_name'] ?? '').toString().trim();
    if (dn.isNotEmpty) return dn;
    final email = (p['email'] ?? '').toString();
    return email.isNotEmpty ? email.split('@').first : 'User';
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _openChats() async {
    if (myManagers.isEmpty) {
      _snack('No managers yet');
      return;
    }
    await context.push('/chats', extra: myManagers);
    _refreshUnread();
  }

  Future<void> _openChatWithManager(Map<String, dynamic> row) async {
    try {
      final p = (row['manager_profile'] as Map<String, dynamic>?) ?? row;

      String? otherId;
      for (final k in ['manager_id', 'user_id', 'id', 'uid', 'profile_id']) {
        final v = row[k] ?? p[k];
        if (v != null && v.toString().isNotEmpty) {
          otherId = v.toString();
          break;
        }
      }

      if (otherId == null) {
        final email = (p['email'] ?? row['email'])?.toString();
        if (email != null && email.isNotEmpty) {
          final hit = await Supabase.instance.client
              .from('profiles')
              .select('id')
              .eq('email', email)
              .maybeSingle();
          if (hit != null && hit['id'] != null) otherId = hit['id'] as String;
        }
      }

      if (otherId == null) {
        _snack('Could not find manager id');
        return;
      }

      final chatId = await _chat.getOrCreateDirectChatWith(otherId);
      if (!mounted) return;
      await context.push('/chats/$chatId');
      _refreshUnread();
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Future<void> _accept(int requestId) async {
    await _auth.respondToRequest(requestId, true);
    _snack('Request accepted');
    await _load();
  }

  Future<void> _reject(int requestId) async {
    await _auth.respondToRequest(requestId, false);
    _snack('Request rejected');
    await _load();
  }

  void _onTapHome() {
    if (!_pageScrollC.hasClients) return;
    _pageScrollC.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );
  }

  Future<void> _openSettings() async {
    final changed = await context.push('/settings') as bool?;
    if (changed == true) _load();
  }

  // ===== helpers for Contract Scanner dialog =====
  List<Map<String, dynamic>> _coerceProsCons(dynamic v) {
    if (v is! List) return [];
    return v.map<Map<String, dynamic>>((e) {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        m['title'] = (m['title'] ?? '').toString();
        m['why_it_matters'] = (m['why_it_matters'] ?? '').toString();
        return m;
      }
      final s = e.toString();
      return {'title': s, 'why_it_matters': ''};
    }).toList();
  }

  List<Map<String, dynamic>> _coerceRedFlags(dynamic v) {
    if (v is! List) return [];
    return v.map<Map<String, dynamic>>((e) {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        return {
          'clause': (m['clause'] ?? '').toString(),
          'severity': (m['severity'] ?? 'medium').toString(),
          'explanation': (m['explanation'] ?? '').toString(),
          'suggested_language': (m['suggested_language'] ?? '').toString(),
          'source_excerpt': (m['source_excerpt'] ?? m['excerpt'] ?? '')
              .toString(),
        };
      }
      final s = e.toString();
      return {
        'clause': s,
        'severity': 'medium',
        'explanation': '',
        'suggested_language': '',
        'source_excerpt': '',
      };
    }).toList();
  }

  List<Map<String, dynamic>> _coerceKeyClauses(dynamic v) {
    if (v is! List) return [];
    return v.map<Map<String, dynamic>>((e) {
      if (e is Map) {
        final m = Map<String, dynamic>.from(e);
        return {
          'name': (m['name'] ?? '').toString(),
          'found': (m['found'] ?? true) == true,
          'excerpt': (m['excerpt'] ?? '').toString(),
        };
      }
      final s = e.toString();
      return {'name': 'Clause', 'found': true, 'excerpt': s};
    }).toList();
  }

  // ===== Contract Scanner dialog (styled)
  void _showAnalysisDialogNew(Map<String, dynamic> raw) {
    final data0 = Map<String, dynamic>.from(raw);
    final Map<String, dynamic> data = data0['result'] is Map
        ? Map<String, dynamic>.from(data0['result'])
        : data0;

    final summary = (data['summary'] ?? '').toString();
    final pros = _coerceProsCons(data['pros']);
    final cons = _coerceProsCons(data['cons']);
    final redFlags = _coerceRedFlags(data['red_flags']);
    final keyClauses = _coerceKeyClauses(data['key_clauses']);

    final levers = (data['negotiation_levers'] as List? ?? [])
        .map((e) => e.toString())
        .where((s) => s.trim().isNotEmpty)
        .toList();

    final questions = (data['questions_for_counterparty'] as List? ?? [])
        .map((e) => e.toString())
        .where((s) => s.trim().isNotEmpty)
        .toList();

    final int score = (data['risk_score'] is num)
        ? _clampScore((data['risk_score'] as num).round())
        : _computeSafetyScore(pros, cons, redFlags);

    final String label =
        (data['risk_label']?.toString().trim().isNotEmpty ?? false)
        ? data['risk_label'].toString()
        : _safetyLabel(score);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.92,
          child: Column(
            children: [
              // Header
              Container(
                width: double.infinity,
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Container(
                      width: 40,
                      height: 4,
                      margin: const EdgeInsets.only(bottom: 12),
                      decoration: BoxDecoration(
                        color: Colors.black12,
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'AI Contract Scanner',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // Body
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (summary.isNotEmpty)
                        _SectionCard(title: 'Summary', child: Text(summary)),

                      const SizedBox(height: 8),
                      Center(
                        child: RiskFace(
                          score: score.toDouble(),
                          label: label,
                          size: 180.0,
                        ),
                      ),
                      const SizedBox(height: 16),

                      if (pros.isNotEmpty || cons.isNotEmpty)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if (pros.isNotEmpty)
                              Expanded(
                                child: _SectionCard(
                                  title: 'Pros',
                                  child: _proConList(pros, positive: true),
                                ),
                              ),
                            if (pros.isNotEmpty && cons.isNotEmpty)
                              const SizedBox(width: 12),
                            if (cons.isNotEmpty)
                              Expanded(
                                child: _SectionCard(
                                  title: 'Cons',
                                  child: _proConList(cons, positive: false),
                                ),
                              ),
                          ],
                        ),

                      if (redFlags.isNotEmpty)
                        _expandableSection(
                          title: 'Risks / red flags',
                          child: Column(
                            children: redFlags
                                .map(
                                  (f) => Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: 10.0,
                                    ),
                                    child: _redFlagTile(f),
                                  ),
                                )
                                .toList(),
                          ),
                          initiallyExpanded: false,
                          bgColor: const Color(0xFFFFF5F5),
                          accentColor: Colors.redAccent,
                          count: redFlags.length,
                        ),

                      if (keyClauses.isNotEmpty)
                        _expandableSection(
                          title: 'Key points we found',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: keyClauses
                                .map(
                                  (m) => Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('•  '),
                                        Expanded(
                                          child: Text(
                                            '${m['name']}: ${m['excerpt']}',
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                          initiallyExpanded: false,
                          bgColor: const Color(0xFFF5F6FA),
                          accentColor: Colors.grey,
                        ),

                      if (questions.isNotEmpty)
                        _expandableSection(
                          title: 'Questions for the other side',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: questions
                                .map(
                                  (t) => Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('•  '),
                                        Expanded(child: Text(t)),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                          initiallyExpanded: false,
                          bgColor: const Color(0xFFF5F6FA),
                          accentColor: Colors.grey,
                        ),

                      if (levers.length > 1)
                        _expandableSection(
                          title: 'More negotiation levers',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: levers
                                .skip(1)
                                .map(
                                  (t) => Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        const Text('•  '),
                                        Expanded(child: Text(t)),
                                      ],
                                    ),
                                  ),
                                )
                                .toList(),
                          ),
                          initiallyExpanded: false,
                        ),

                      const SizedBox(height: 8),
                      Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () async {
                                try {
                                  final url = _lastUpload?.fileUrl;
                                  if (url == null) {
                                    _snack(
                                      'No upload URL found. Please re-upload the file.',
                                    );
                                    return;
                                  }
                                  await _promptAndSaveAnalysis(
                                    analysisData: data,
                                    fileUrl: _lastUpload!.fileUrl,
                                  );
                                  if (mounted) Navigator.pop(context);
                                } catch (e) {
                                  _snack('Error saving: $e');
                                }
                              },
                              icon: const Icon(Icons.save),
                              label: const Text('Save analysis'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          SizedBox(
                            width: double.infinity,
                            child: ElevatedButton.icon(
                              onPressed: () => Navigator.pop(context),
                              icon: const Icon(Icons.check),
                              label: const Text('Done'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF6C63FF),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 14,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<String> _toList(dynamic v) {
    if (v == null) return [];
    if (v is String) return v.trim().isEmpty ? [] : [v.trim()];
    if (v is List) {
      return v
          .map((e) => e?.toString() ?? '')
          .where((s) => s.trim().isNotEmpty)
          .toList();
    }
    if (v is Map) {
      return v.entries.map((e) => '${e.key}: ${e.value}').toList();
    }
    return [v.toString()];
  }

  Widget _proConList(
    List<Map<String, dynamic>> items, {
    required bool positive,
  }) {
    final icon = positive
        ? Icons.check_circle_outline
        : Icons.warning_amber_outlined;
    final color = positive ? Colors.green : Colors.amber;
    return Column(
      children: items.map((m) {
        final title = (m['title'] ?? '').toString();
        final why = (m['why_it_matters'] ?? '').toString();
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (why.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(why),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  int _weightForSeverity(String s) {
    switch (s.toLowerCase()) {
      case 'high':
        return 25;
      case 'medium':
        return 15;
      case 'low':
        return 8;
      default:
        return 12;
    }
  }

  int _computeSafetyScore(
    List<Map<String, dynamic>> pros,
    List<Map<String, dynamic>> cons,
    List<Map<String, dynamic>> redFlags,
  ) {
    double score = 70;
    score += (pros.length * 4);
    score -= (cons.length * 4);
    for (final f in redFlags) {
      final sev = (f['severity'] ?? '').toString();
      score -= _weightForSeverity(sev);
    }
    if (score < 0) score = 0;
    if (score > 100) score = 100;
    return score.round();
  }

  int _clampScore(int s) => s < 0 ? 0 : (s > 100 ? 100 : s);

  String _safetyLabel(int score) {
    if (score >= 85) return 'Safe to sign (low risk)';
    if (score >= 70) return 'Mostly OK (minor fixes)';
    if (score >= 55) return 'Caution (needs changes)';
    if (score >= 40) return 'Risky (major changes)';
    return 'Do not sign as-is';
  }

  Widget _redFlagTile(Map<String, dynamic> f) {
    final clause = (f['clause'] ?? '').toString().trim();
    final why = (f['explanation'] ?? '').toString().trim();
    final source = (f['source_excerpt'] ?? '').toString().trim();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            clause.isEmpty ? 'Clause' : clause,
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
          if (source.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF7F7FF),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _accent.withOpacity(0.25)),
              ),
              child: Text(
                '“$source”',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          ],
          if (why.isNotEmpty) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: const [
                Icon(Icons.warning_amber_outlined, color: Colors.orange),
                SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Why this is risky',
                    style: TextStyle(fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(why),
          ],
        ],
      ),
    );
  }

  Widget _expandableSection({
    required String title,
    required Widget child,
    bool initiallyExpanded = false,
    Color? bgColor,
    Color? accentColor,
    int? count,
  }) {
    bool expanded = initiallyExpanded;
    final Color acc = accentColor ?? _accent;
    final Color bg = bgColor ?? Colors.white;
    final Color border = (bgColor == null)
        ? Colors.black12
        : acc.withOpacity(0.25);
    final Color chipBg = acc.withOpacity(0.12);
    final Color chipBorder = acc.withOpacity(0.30);

    return StatefulBuilder(
      builder: (ctx, setSB) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 14,
                        ),
                      ),
                      if (count != null) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: chipBg,
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: chipBorder),
                          ),
                          child: Text(
                            count.toString(),
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 12,
                              color: acc,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                InkWell(
                  onTap: () => setSB(() => expanded = !expanded),
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: acc.withOpacity(0.10),
                      border: Border.all(color: acc.withOpacity(0.30)),
                    ),
                    child: Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 18,
                      color: acc,
                    ),
                  ),
                ),
              ],
            ),
            if (expanded) ...[const SizedBox(height: 8), child],
          ],
        ),
      ),
    );
  }

  Future<void> _promptAndSaveAnalysis({
    required Map<String, dynamic> analysisData,
    required String fileUrl,
  }) async {
    final controller = TextEditingController(text: 'Untitled contract');

    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final kb = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, kb + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Save analysis',
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                decoration: InputDecoration(
                  labelText: 'Title',
                  filled: true,
                  fillColor: const Color(0xFFF5F6FA),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx, true),
                  icon: const Icon(Icons.save),
                  label: const Text('Save'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (saved == true) {
      await _contracts.saveAnalysis(
        fileUrl: fileUrl,
        analysis: analysisData,
        title: controller.text.trim().isEmpty
            ? 'Contract'
            : controller.text.trim(),
        forUserId: me?.id,
        forDisplayName: me?.displayName ?? me?.email,
      );
      _snack('Analysis saved!');
    }
  }

  // ---------- Header ----------
  Widget _header() {
    final topInset = MediaQuery.of(context).padding.top;
    final name = (me?.displayName?.trim().isNotEmpty ?? false)
        ? me!.displayName!
        : (me?.email ?? 'Artist');
    final avatarUrl = (me?.avatarUrl ?? '').toString();

    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(28)),
      child: Container(
        height: kHeaderHeight,
        padding: EdgeInsets.fromLTRB(16, topInset + kHeaderTopExtra, 16, 12),
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-1, -1),
            end: Alignment(1, 1),
            colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: kGreetingTopPadding),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _avatar(
                    label: name,
                    avatarUrl: avatarUrl,
                    size: kManagerAvatarSize,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.95),
                            fontSize: 20,
                            fontWeight: FontWeight.w400,
                            height: 1.1,
                          ),
                        ),
                        const Text(
                          'Welcome back,',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w300,
                            height: 1.05,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- Managers carousel ----------
  Widget _managersCarousel() {
    if (myManagers.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          'No managers yet.',
          style: TextStyle(color: Colors.black54),
        ),
      );
    }

    return SizedBox(
      height: kCardRowHeight,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: myManagers.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final row = myManagers[i];
          final p = (row['manager_profile'] as Map<String, dynamic>?) ?? row;
          final title = _displayName(p);
          final avatarUrl = (p['avatar_url'] ?? '').toString();

          return InkWell(
            onTap: () => _openChatWithManager(row),
            borderRadius: BorderRadius.circular(18),
            child: Container(
              width: kCardWidth,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.06),
                    blurRadius: 14,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _avatar(label: title, avatarUrl: avatarUrl, size: 40),
                      const Spacer(),
                      const Icon(
                        Icons.chevron_right,
                        color: Colors.black54,
                        size: 22,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Color(0xFF1F1F1F),
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Manager',
                    style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ---------- Body ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF4F5FB),
      extendBody: true,
      body: loading
          ? const Center(child: CircularProgressIndicator())
          : SafeArea(
              top: false,
              child: SingleChildScrollView(
                controller: _pageScrollC,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),

                    // Pull content up over header's curved bottom
                    Transform.translate(
                      offset: const Offset(0, -kManagedOverlap),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(height: kAfterHeaderGap),
                          const Padding(
                            padding: EdgeInsets.only(
                              left: 16,
                              right: 16,
                              bottom: 0,
                            ),
                            child: Text(
                              'Your managers',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 20,
                                color: Color.fromARGB(221, 255, 255, 255),
                              ),
                            ),
                          ),
                          SizedBox(height: kLabelToCardsGap),
                          _managersCarousel(),

                          // Shared To-Dos
                          const SizedBox(height: 16),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              '',
                              style: TextStyle(
                                color: Colors.black87,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: TodoPanel(
                              managedRows: managedRowsForArtist,
                              currentRole: 'artist', // lock assignee to “Me”
                            ),
                          ),

                          // ---- AI Contract Scanner (artist) ----
                          const SizedBox(height: 20),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'AI Contract Scanner',
                              style: TextStyle(
                                color: Colors.black87,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SizedBox(
                                    height: 56,
                                    child: ElevatedButton.icon(
                                      onPressed: _uploadAndScan,
                                      icon: const Icon(
                                        Icons.document_scanner_outlined,
                                        size: 24,
                                      ),
                                      label: const Text('Upload & analyze'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFFF4C61F,
                                        ),
                                        foregroundColor: const Color(
                                          0xFF1F1F1F,
                                        ),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            15,
                                          ),
                                          side: const BorderSide(
                                            color: Colors.black12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: SizedBox(
                                    height: 56,
                                    child: ElevatedButton.icon(
                                      onPressed: () async {
                                        try {
                                          final analyses = await _contracts
                                              .listSavedAnalyses();
                                          if (!mounted) return;
                                          await Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) => SavedAnalysesPage(
                                                analyses: analyses,
                                              ),
                                            ),
                                          );
                                        } catch (e) {
                                          if (!mounted) return;
                                          _snack('Could not load analyses: $e');
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.bookmark_outline,
                                        size: 24,
                                      ),
                                      label: const Text('Saved'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(
                                          0xFFB6D6DE,
                                        ),
                                        foregroundColor: const Color(
                                          0xFF1F1F1F,
                                        ),
                                        elevation: 0,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          side: const BorderSide(
                                            color: Colors.black12,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 110),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

      // Bottom bar + centered FAB (chat)
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Transform.translate(
        offset: const Offset(0, kFabYOffset),
        child: SizedBox(
          width: kFabDiameter,
          height: kFabDiameter,
          child: FloatingActionButton(
            heroTag: 'artistMainFab',
            backgroundColor: const Color.fromRGBO(44, 60, 96, 1),
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            onPressed: _openChats,
            child: const Icon(Icons.chat_bubble_outline, size: 26),
          ),
        ),
      ),
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
                      icon: Icons.people_outline,
                      label: 'Managers',
                      onTap: () {},
                    ),
                  ],
                ),
              ),
              SizedBox(width: kFabGapWidth),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(
                  children: [
                    _BottomItem(
                      icon: Icons.chat_bubble_outline,
                      label: _unreadTotal > 0
                          ? 'Messages ($_unreadTotal)'
                          : 'Messages',
                      onTap: _openChats,
                    ),
                    const SizedBox(width: 28),
                    _BottomItem(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      onTap: _openSettings,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---- Small labeled bottom bar item (same as Manager) ----
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

// ---- Reusable tiny section card (same look as Manager) ----
class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 14),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
