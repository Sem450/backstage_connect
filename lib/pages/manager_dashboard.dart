import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;

import 'package:file_picker/file_picker.dart';

import '../models/uploaded_contract.dart';
import '../services/contract_service.dart';
import '../widgets/risk_face.dart';
import 'saved_analyses_page.dart';
import '../utils/errors.dart';


import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'revenue_entries_page.dart'; // add this

import 'package:flutter/cupertino.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';


import '../models/app_user.dart';

import '../services/auth_service.dart';
import '../services/chat_service.dart';

import '../widgets/todo_panel.dart';

import '../services/revenue_service.dart';
import '../models/revenue_entry.dart';

import 'package:fl_chart/fl_chart.dart';

enum EarningsRange { day, week, month, year }

class ManagerDashboard extends StatefulWidget {
  const ManagerDashboard({super.key});

  @override
  State<ManagerDashboard> createState() => _ManagerDashboardState();
}

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

class _ManagerDashboardState extends State<ManagerDashboard> {
  // ---- Layout knobs ----
  static const double kHeaderHeight = 190;
  static const double kHeaderTopExtra = 6;
  static const double kManagedOverlap = 120;
  static const double kCardRowHeight = 170;
  static const double kCardWidth = 260;

  static const double kAfterHeaderGap = 28;
  static const double kLabelToCardsGap = 12;

  static const double kGreetingTopPadding = 8;
  static const double kManagerAvatarSize = 75;

  static const double kFabDiameter = 52;
  static const double kFabYOffset = 30;
  static const double kFabGapWidth = 80;
  static const double kBarHeight = 64;

  EarningsRange _range = EarningsRange.month; // default
  double _overallTotal = 0.0;

  // ---- earnings debug/guard ----
  bool _earningsInFlight = false;
  int _refreshCount = 0;

  // optional: track how many dashboard instances get created
  static int _instanceCounter = 0;
  late final int _instanceId;

  static const _accent = Color(0xFF6C63FF);

  final _auth = AuthService();
  final _contracts = ContractService();
  final _chat = ChatService();
  final _revenue = RevenueService();

  final codeC = TextEditingController();
  final _pageScrollC = ScrollController();

  AppUser? me;
  List<Map<String, dynamic>> managed = [];
  List<Map<String, dynamic>> outgoing = [];
  List<ArtistEarnings> _earnings = [];

  bool loading = true;
  String? error;

  UploadedContract? _lastUpload; // remember the last uploaded contract

  int _unreadTotal = 0;
  Timer? _badgeTimer;

  void _openAddArtistSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Add artist by code',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: codeC,
              decoration: InputDecoration(
                hintText: 'Enter artist code (e.g., a1b2c3d4)',
                filled: true,
                fillColor: const Color.fromARGB(255, 109, 108, 108),
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
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _sendRequestByCode();
                },
                icon: const Icon(Icons.send),
                label: const Text('Send request'),
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
      ),
    );
  }

  // ---- scanning overlay ----
  final ValueNotifier<String> _scanStatus = ValueNotifier<String>('Starting…');

  String _displayName(Map<String, dynamic> p) {
    final dn = (p['display_name'] ?? '').toString().trim();
    if (dn.isNotEmpty) return dn;
    final email = (p['email'] ?? '').toString();
    return email.isNotEmpty ? email.split('@').first : 'User';
  }

  @override
  void initState() {
    super.initState();
    _instanceId = ++_instanceCounter;
    debugPrint('🧩 ManagerDashboard initState (instance #$_instanceId)');

    _load();
    _badgeTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _refreshUnread(),
    );
  }

  @override
  void dispose() {
    _badgeTimer?.cancel();
    codeC.dispose();
    _pageScrollC.dispose();
    super.dispose();
  }

  // ----- Data -----
  Future<void> _load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      me = await _auth.currentProfile();
      managed = await _auth.managedArtists();
      outgoing = await _auth.outgoingRequestsPending();
      await _refreshUnread();

      // 👇 add this
      await _refreshEarnings();
    } catch (e) {
      error = e.toString();
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  String? _topEarnerId;

  Future<void> _pickRange(BuildContext context) async {
    final picked = await showModalBottomSheet<EarningsRange>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        // 👈 HERE — use ctx instead of _
        Widget tile(EarningsRange r, String label) => ListTile(
          title: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          trailing: _range == r
              ? const Icon(Icons.check, color: Color(0xFF6C63FF))
              : null,
          onTap: () => Navigator.pop(ctx, r), // 👈 now ctx is defined
        );

        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 6),
              Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black12,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 8),
              tile(EarningsRange.day, 'Day'),
              tile(EarningsRange.week, 'Week'),
              tile(EarningsRange.month, 'Month'),
              tile(EarningsRange.year, 'Year'),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );

    if (picked != null) {
      setState(() => _range = picked);
      await _refreshEarnings();
    }
  }

  Future<void> _refreshEarnings() async {
    if (_earningsInFlight) {
      debugPrint('⚠️ _refreshEarnings ignored (already running)');
      return;
    }
    _earningsInFlight = true;
    final callNo = ++_refreshCount;
    debugPrint('➡️ _refreshEarnings #$callNo, range=$_range');
    // who called me?
    debugPrint(StackTrace.current.toString().split('\n').take(6).join('\n'));

    try {
      if (me?.id == null) return;

      // Decide the date window based on the selected filter
      DateTime? from;
      DateTime? to;

      final now = DateTime.now();
      switch (_range) {
        case EarningsRange.day:
          from = DateTime(now.year, now.month, now.day);
          to = DateTime(now.year, now.month, now.day, 23, 59, 59);
          break;
        case EarningsRange.week:
          final weekday = now.weekday; // Mon=1..Sun=7
          from = DateTime(
            now.year,
            now.month,
            now.day,
          ).subtract(Duration(days: weekday - 1));
          to = from.add(const Duration(days: 6));
          break;
        case EarningsRange.month:
          from = DateTime(now.year, now.month, 1);
          to = DateTime(now.year, now.month + 1, 0);
          break;
        case EarningsRange.year:
          from = DateTime(now.year, 1, 1);
          to = DateTime(now.year, 12, 31);
          break;
      }
      debugPrint("📊 Refreshing earnings with range: $_range");
      debugPrint("   From: $from");
      debugPrint("   To:   $to");

      final data = await _revenue.totalsByArtistInRange(
        me!.id,
        from: from,
        to: to,
      );

      double overall = 0;
      for (final e in data) {
        overall += e.totalManagerEarnings;
      }

      if (!mounted) return;
      setState(() {
        _earnings = data;
        _overallTotal = overall;
        _topEarnerId = data.isNotEmpty
            ? data.first.artistId
            : null; // 👑 save top earner
      });
      debugPrint(
        '✅ updated: ${data.length} artists, total £${overall.toStringAsFixed(2)}',
      );
    } finally {
      _earningsInFlight = false;
    }
  }

  Future<void> _promptAndSaveAnalysis({
    required Map<String, dynamic> analysisData,
    required String fileUrl,
  }) async {
    final controller = TextEditingController(text: 'Untitled contract');

    // Build a list of (id, label) from your managed artists
    final managedPeople = managed
        .map<Map<String, String>>((row) {
          final p = (row['artist_profile'] as Map<String, dynamic>?) ?? {};
          final id = (row['artist_id'] ?? p['id'] ?? '').toString();
          final label = (p['display_name'] ?? p['email'] ?? 'Artist')
              .toString();
          return {'id': id, 'label': label};
        })
        .where((m) => m['id']!.isNotEmpty)
        .toList();

    String? selectedId = managedPeople.isNotEmpty
        ? managedPeople.first['id']
        : null;
    String? selectedLabel = managedPeople.isNotEmpty
        ? managedPeople.first['label']
        : null;

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
              const SizedBox(height: 12),
              if (managedPeople.isNotEmpty) ...[
                const Text(
                  'Who is this for?',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                StatefulBuilder(
                  builder: (ctx, setSB) {
                    return DropdownButtonFormField<String>(
                      value: selectedId,
                      items: managedPeople.map((m) {
                        return DropdownMenuItem<String>(
                          value: m['id'],
                          child: Text(m['label']!),
                        );
                      }).toList(),
                      onChanged: (v) {
                        setSB(() {
                          selectedId = v;
                          selectedLabel = managedPeople.firstWhere(
                            (e) => e['id'] == v,
                          )['label'];
                        });
                      },
                      decoration: InputDecoration(
                        filled: true,
                        fillColor: const Color(0xFFF5F6FA),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 8),
                const Text(
                  'Tip: leave as first option if you just want to save it without a specific artist.',
                ),
              ] else
                const Text(
                  'No managed artists yet. You can still save the analysis.',
                  style: TextStyle(color: Colors.black54),
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

    if (saved != true) return;

    try {
      await _contracts.saveAnalysis(
        fileUrl: fileUrl,
        analysis: analysisData,
        title: controller.text.trim().isEmpty
            ? 'Contract'
            : controller.text.trim(),
        forUserId: selectedId,
        forDisplayName: selectedLabel,
      );
      _snack('Analysis saved!');
    } catch (e) {
      _snack('Error saving: $e');
    }
  }

  Future<void> _refreshUnread() async {
    try {
      final n = await _chat.unreadTotal();
      if (!mounted) return;
      setState(() => _unreadTotal = n);
    } catch (_) {
      if (mounted) setState(() => _unreadTotal = 0);
    }
  }

  // ----- Revenue actions -----
  void _openArtistActions(Map<String, dynamic> row) {
    final p = (row['artist_profile'] as Map<String, dynamic>?) ?? {};
    final artistId = (row['artist_id'] ?? p['id'] ?? '').toString();
    final title = _displayName(p);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.black12,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.chat_bubble_outline),
              title: const Text('Message'),
              onTap: () {
                Navigator.pop(context);
                _openChatWithRow(row);
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('See saved contracts'),
              onTap: () {
                Navigator.pop(context);
                _openSavedAnalyses();
              },
            ),
            ListTile(
              leading: const Icon(Icons.list_alt_outlined),
              title: const Text('View revenue sources'),
              onTap: () {
                Navigator.pop(context);
                final p =
                    (row['artist_profile'] as Map<String, dynamic>?) ?? {};
                final artistId = (row['artist_id'] ?? p['id'] ?? '').toString();
                final artistName = _displayName(p);
                Navigator.of(context)
                    .push(
                      MaterialPageRoute(
                        builder: (_) => RevenueEntriesPage(
                          managerId: me!.id,
                          artistId: artistId,
                          artistName: artistName,
                        ),
                      ),
                    )
                    .then((_) {
                      // Refresh the chart totals after edits/deletes
                      _refreshEarnings();
                    });
              },
            ),

            ListTile(
              leading: const Icon(Icons.percent),
              title: const Text('Set commission rate'),
              onTap: () {
                Navigator.pop(context);
                _showSetCommissionSheet(artistId, title);
              },
            ),
            ListTile(
              leading: const Icon(Icons.add_card),
              title: const Text('Add revenue source'),
              onTap: () {
                Navigator.pop(context);
                _showAddRevenueDialog(artistId, title);
              },
            ),
            const SizedBox(height: 10),
          ],
        ),
      ),
    );
  }

  void _showSetCommissionSheet(String artistId, String artistName) async {
    final c = TextEditingController();
    final managerId = me?.id ?? '';
    double? existing = await _revenue.getDefaultCommissionRate(
      managerId: managerId,
      artistId: artistId,
    );
    if (existing != null) c.text = existing.toStringAsFixed(2);

    showModalBottomSheet(
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
              Text(
                'Set commission for $artistName',
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 18,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: c,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: 'Commission %',
                  suffixText: '%',
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
                child: ElevatedButton(
                  onPressed: () async {
                    final v = double.tryParse(c.text.trim());
                    if (v == null || v < 0 || v > 100) {
                      _snack('Enter a valid % between 0 and 100');
                      return;
                    }
                    try {
                      await _revenue.setDefaultCommissionRate(
                        managerId: managerId,
                        artistId: artistId,
                        ratePercent: v,
                      );
                      if (!mounted) return;
                      Navigator.pop(ctx);
                      _snack('Commission updated');
                    } catch (e) {
                      _snack('Error: $e');
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF6C63FF),
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('Save'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showAddRevenueDialog(String artistId, String artistName) async {
    final titleC = TextEditingController();
    final grossC = TextEditingController();
    final notesC = TextEditingController();
    final commissionC = TextEditingController();
    DateTime when = DateTime.now();

    final managerId = me!.id;
    final defaultRate = await _revenue.getDefaultCommissionRate(
      managerId: managerId,
      artistId: artistId,
    );
    if (defaultRate != null) {
      commissionC.text = defaultRate.toStringAsFixed(2);
    } else {
      commissionC.text = '10.00'; // sensible default
    }

    bool saveAsDefault = false;

    double _calcEarnings() {
      final gross = double.tryParse(grossC.text.trim()) ?? 0.0;
      final rate = double.tryParse(commissionC.text.trim()) ?? 0.0;
      return gross * (rate / 100.0);
    }

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return DraggableScrollableSheet(
          initialChildSize: 0.75,
          minChildSize: 0.6,
          maxChildSize: 0.92,
          expand: false,
          builder: (_, controller) {
            return Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(22),
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.08),
                    blurRadius: 24,
                    offset: const Offset(0, -8),
                  ),
                ],
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: EdgeInsets.only(
                    left: 16,
                    right: 16,
                    bottom: MediaQuery.of(ctx).viewInsets.bottom + 12,
                    top: 10,
                  ),
                  child: StatefulBuilder(
                    builder: (ctx, setSB) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Grabber + Title
                        Center(
                          child: Container(
                            width: 44,
                            height: 5,
                            decoration: BoxDecoration(
                              color: Colors.black12,
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Text(
                              'Add revenue • $artistName',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Spacer(),
                            IconButton(
                              onPressed: () => Navigator.pop(ctx),
                              icon: const Icon(Icons.close_rounded),
                              tooltip: 'Close',
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),

                        // Scroll area
                        Expanded(
                          child: ListView(
                            controller: controller,
                            padding: EdgeInsets.zero,
                            children: [
                              // Title
                              _Field(
                                label: 'Title',
                                hint: 'e.g. Spotify Q2',
                                controller: titleC,
                                icon: Icons.title_rounded,
                              ),
                              const SizedBox(height: 10),

                              // Gross + Commission side by side
                              Row(
                                children: [
                                  Expanded(
                                    child: _Field(
                                      label: 'Gross amount',
                                      hint: 'What artist made',
                                      controller: grossC,
                                      icon: Icons.attach_money_rounded,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      prefix: const Text('£ '),
                                      onChanged: (_) => setSB(() {}),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _Field(
                                      label: 'Your commission %',
                                      hint: 'e.g. 10',
                                      controller: commissionC,
                                      icon: Icons.percent_rounded,
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      suffix: const Text('%'),
                                      onChanged: (_) => setSB(() {}),
                                    ),
                                  ),
                                ],
                              ),

                              // Save default
                              const SizedBox(height: 6),
                              CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                controlAffinity:
                                    ListTileControlAffinity.leading,
                                value: saveAsDefault,
                                onChanged: (v) =>
                                    setSB(() => saveAsDefault = v ?? false),
                                title: const Text(
                                  'Save this % as default for this artist',
                                ),
                              ),

                              // Date row
                              // Date row
                              const SizedBox(height: 4),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF7F7FB),
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(color: Colors.black12),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.event_outlined),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Date • ${when.toIso8601String().split('T').first}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () async {
                                        await showModalBottomSheet(
                                          context: ctx,
                                          backgroundColor: Colors.white,
                                          shape: const RoundedRectangleBorder(
                                            borderRadius: BorderRadius.vertical(
                                              top: Radius.circular(16),
                                            ),
                                          ),
                                          builder: (_) {
                                            return SizedBox(
                                              height: 250,
                                              child: CupertinoDatePicker(
                                                initialDateTime: when,
                                                maximumDate: DateTime.now().add(
                                                  const Duration(days: 365 * 5),
                                                ),
                                                minimumDate: DateTime(2015),
                                                mode: CupertinoDatePickerMode
                                                    .date,
                                                onDateTimeChanged: (picked) {
                                                  when = picked;
                                                  setSB(() {});
                                                },
                                              ),
                                            );
                                          },
                                        );
                                      },
                                      child: const Text('Change'),
                                    ),
                                  ],
                                ),
                              ),

                              const SizedBox(height: 10),
                              _Field(
                                label: 'Notes (optional)',
                                hint: 'Add context for future you…',
                                controller: notesC,
                                icon: Icons.sticky_note_2_outlined,
                                maxLines: 3,
                              ),

                              const SizedBox(height: 12),
                              _PreviewCard(
                                grossStr: grossC.text,
                                rateStr: commissionC.text,
                                computed: _calcEarnings(),
                              ),
                              const SizedBox(height: 6),
                            ],
                          ),
                        ),

                        // Buttons
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () => Navigator.pop(ctx),
                                style: OutlinedButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 14,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                                child: const Text('Cancel'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () async {
                                  final title = titleC.text.trim();
                                  final gross = double.tryParse(
                                    grossC.text.trim(),
                                  );
                                  final rate = double.tryParse(
                                    commissionC.text.trim(),
                                  );

                                  if (title.isEmpty) {
                                    _snack('Please enter a title');
                                    return;
                                  }
                                  if (gross == null || gross < 0) {
                                    _snack('Enter a valid gross amount');
                                    return;
                                  }
                                  if (rate == null || rate < 0 || rate > 100) {
                                    _snack('Enter a valid % between 0 and 100');
                                    return;
                                  }

                                  try {
                                    if (saveAsDefault) {
                                      await _revenue.setDefaultCommissionRate(
                                        managerId: managerId,
                                        artistId: artistId,
                                        ratePercent: rate,
                                      );
                                    }

                                    final entry = await _revenue
                                        .addRevenueEntry(
                                          managerId: managerId,
                                          artistId: artistId,
                                          title: title,
                                          grossAmount: gross,
                                          occurredOn: when,
                                          commissionRateOverride: rate,
                                          notes: notesC.text.trim().isEmpty
                                              ? null
                                              : notesC.text.trim(),
                                        );

                                    await _refreshEarnings(); // <- recomputes _earnings + _overallTotal
                                    if (!mounted) return;
                                    Navigator.pop(ctx);
                                    _snack(
                                      'Revenue saved (+£${entry.managerEarnings.toStringAsFixed(2)})',
                                    );
                                  } catch (e) {
                                    _snack('Error: $e');
                                  }
                                },
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
                                child: const Text('Save'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
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
                  children: [
                    const CircularProgressIndicator(
                      strokeWidth: 6,
                      valueColor: AlwaysStoppedAnimation<Color>(_accent),
                      backgroundColor: Colors.black12,
                    ),
                    const Icon(
                      Icons.description_outlined,
                      size: 26,
                      color: _accent,
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

  // ----- Chat / contracts actions -----
  Future<void> _openChats() async {
    if (managed.isEmpty) {
      _snack('No managed artists yet');
      return;
    }
    await context.push('/chats', extra: managed);
    _refreshUnread();
  }

  Future<void> _openChatWithRow(Map<String, dynamic> row) async {
    try {
      final p = (row['artist_profile'] as Map<String, dynamic>?) ?? row;
      String? otherId;

      for (final k in ['artist_id', 'user_id', 'id', 'uid', 'profile_id']) {
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
              .select('id,display_name,email,avatar_url')
              .eq('email', email)
              .maybeSingle();
          if (hit != null && hit['id'] != null) {
            otherId = hit['id'] as String;
            p['display_name'] = hit['display_name'];
            p['avatar_url'] = hit['avatar_url'];
          }
        }
      }

      if (otherId == null) {
        _snack('Could not find this artist’s user id');
        return;
      }

      final chatId = await _chat.getOrCreateDirectChatWith(otherId);
      if (!mounted) return;

      final title = (p['display_name'] ?? p['email'] ?? 'Chat').toString();
      final avatar = (p['avatar_url'] ?? '').toString().trim();

      await context.push(
        '/chats/$chatId',
        extra: {
          'initialTitle': title,
          'initialAvatarUrl': avatar.isEmpty ? null : avatar,
        },
      );
      _refreshUnread();
    } catch (e) {
      _snack('Error: $e');
    }
  }

  Future<void> _sendRequestByCode() async {
    try {
      final code = codeC.text.trim();
      if (code.isEmpty) {
        _snack('Enter an artist code');
        return;
      }
      await _auth.sendRequestByArtistCode(code);
      codeC.clear();
      _snack('Request sent!');
      await _load();
    } catch (e) {
      _snack('Error: $e');
    }
  }

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
    if (changed == true) {
      _load(); // re-fetch me + managed artists and rebuild
    }
  }

  Future<void> _openSavedAnalyses() async {
    try {
      final analyses = await _contracts.listSavedAnalyses();
      if (!mounted) return;

      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => SavedAnalysesPage(analyses: analyses),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not load analyses: $e')));
    }
  }

  // ===== helpers for Contract Scanner dialog =====
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

  // ===== Contract Scanner dialog (schema-aware, styled) =====
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

  // ---------- Header + managed cards ----------
  Widget _header() {
    final topInset = MediaQuery.of(context).padding.top;
    final name = (me?.displayName?.trim().isNotEmpty ?? false)
        ? me!.displayName!
        : (me?.email ?? 'Manager');
    final avatarUrl = (me?.avatarUrl ?? '').toString();

    return ClipRRect(
      child: Container(
        height: kHeaderHeight,
        padding: EdgeInsets.fromLTRB(16, topInset + kHeaderTopExtra, 16, 12),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment(-1, -1),
            end: Alignment(1, 1),
            colors: [
              Color.fromARGB(255, 185, 178, 202),
              Color.fromARGB(255, 117, 114, 166),
            ],
          ),
          image: DecorationImage(
            image: AssetImage('assets/bg.png'), // Add your image path here
            fit: BoxFit.cover, // Makes sure the image fills the container
            // Optional: Adds a dark overlay
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
                            color: const Color.fromARGB(
                              255,
                              255,
                              255,
                              255,
                            ).withOpacity(0.95),
                            fontSize: 19,
                            fontWeight: FontWeight.w600,
                            height: 1.5,
                            letterSpacing: 0.5,
                          ),
                        ),
                        Text(
                          'Welcome back,',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color.fromARGB(255, 193, 180, 215),
                            fontSize: 15,
                            fontWeight: FontWeight.w200,
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

  Widget _managedCarousel() {
    if (managed.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 16),
        child: Text('No artists yet.', style: TextStyle(color: Colors.black54)),
      );
    }

    return SizedBox(
      height: kCardRowHeight,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: managed.length,
        separatorBuilder: (_, __) => const SizedBox(width: 12),
        itemBuilder: (_, i) {
          final row = managed[i];
          final p = (row['artist_profile'] as Map<String, dynamic>?) ?? {};
          final title = _displayName(p);
          final avatarUrl = (p['avatar_url'] ?? '').toString();

          return InkWell(
            onTap: () => _openArtistActions(row),
            onLongPress: () => _openChatWithRow(row),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF1F1F1F),
                            fontWeight: FontWeight.w800,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      if (_topEarnerId != null &&
                          _topEarnerId ==
                              (row['artist_id'] ?? p['id']).toString())
                        const FaIcon(
                          FontAwesomeIcons.crown,
                          color: Colors.amber,
                          size: 16,
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Artist',
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

                          // Padding around "Managed artists" section
                          const Padding(
                            padding: EdgeInsets.only(
                              left: 16,
                              right: 16,
                              bottom: 0,
                              top: 15,
                            ),
                            child: Text(
                              'Managed artists',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 20,
                                color: Color.fromARGB(221, 209, 202, 202),
                              ),
                            ),
                          ),

                          // Top padding for the "Managed artists" section
                          Padding(
                            padding: const EdgeInsets.only(
                              top: 16.0,
                            ), // Adjust this value for top padding
                            child: _managedCarousel(),
                          ),

                          // If no managed artists, add more space before earnings
                          if (managed.isEmpty)
                            const SizedBox(
                              height: 40,
                            ), // Adds extra space before earnings
                          // Earnings section
                          const SizedBox(height: 16),
                          const SizedBox(height: 8),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: _EarningsBarChart(
                              earnings: _earnings,
                              headerTrailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Clean number (no background)
                                  Text(
                                    '£${_overallTotal.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF2E3045),
                                      letterSpacing: 0.2,
                                    ),
                                  ),
                                  const SizedBox(width: 8),

                                  // Filter SVG icon
                                  InkWell(
                                    onTap: () => _pickRange(context),
                                    borderRadius: BorderRadius.circular(10),
                                    child: Container(
                                      width: 36,
                                      height: 36,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: const Color(0xFFE6E7ED),
                                        ),
                                        color: Colors.white,
                                      ),
                                      child: SvgPicture.asset(
                                        'assets/icons/filter.svg',
                                        width: 22,
                                        height: 22,
                                        colorFilter: const ColorFilter.mode(
                                          Color(0xFF3B3E5A),
                                          BlendMode.srcIn,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),

                          // Shared To-Dos
                          const SizedBox(height: 40),
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
                            child: TodoPanel(managedRows: managed),
                          ),

                          // === AI Contract Scanner (moved here, under Shared To-Dos) ===
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
                                // Upload (document scanner icon) — square with rounded corners
                                Expanded(
                                  child: SizedBox(
                                    height: 56, // square-ish button height
                                    child: ElevatedButton.icon(
                                      onPressed: _uploadAndScan,
                                      icon: const Icon(
                                        Icons.document_scanner_outlined,
                                        size: 24,
                                      ),
                                      label: const Text('Upload'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color.fromARGB(
                                          234,
                                          244,
                                          198,
                                          31,
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
                                // Saved — square with rounded corners
                                Expanded(
                                  child: SizedBox(
                                    height: 56,
                                    child: ElevatedButton.icon(
                                      onPressed: _openSavedAnalyses,
                                      icon: const Icon(
                                        Icons.bookmark_outline,
                                        size: 24,
                                      ),
                                      label: const Text('Saved'),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color.fromARGB(
                                          255,
                                          182,
                                          214,
                                          222,
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

                          // Add artist by code (kept where it was after the moved scanner)
                          const SizedBox(height: 24),
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              'Add artist by code',
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
                                  child: TextField(
                                    controller: codeC,
                                    decoration: InputDecoration(
                                      hintText:
                                          'Enter artist code (e.g., a1b2c3d4)',
                                      filled: true,
                                      fillColor: const Color.fromARGB(255, 216, 215, 215),
                                      border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none,
                                      ),
                                      contentPadding:
                                          const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 12,
                                          ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                ElevatedButton.icon(
                                  onPressed: _sendRequestByCode,
                                  icon: const Icon(Icons.send, size: 22),
                                  label: const Text('Send'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF6C63FF),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 14,
                                    ),
                                    shape: RoundedRectangleBorder(),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          const SizedBox(height: 20),

                          if (outgoing.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 16),
                              child: Text(
                                'Pending confirmations',
                                style: TextStyle(
                                  color: Colors.black87,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            ...outgoing.map((r) {
                              final p =
                                  r['artist_profile'] as Map<String, dynamic>?;
                              final title =
                                  p?['display_name'] ?? p?['email'] ?? 'Artist';
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 6,
                                ),
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(14),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withOpacity(0.05),
                                        blurRadius: 12,
                                        offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: ListTile(
                                    leading: _avatar(
                                      label: title.toString(),
                                      avatarUrl: (p?['avatar_url'] ?? '')
                                          .toString(),
                                    ),
                                    title: Text(
                                      title.toString(),
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    subtitle: Text(
                                      'Username: ${p?['display_name'] ?? p?['email'] ?? '—'}',
                                    ),
                                    trailing: const Text(
                                      'Pending',
                                      style: TextStyle(color: Colors.black54),
                                    ),
                                  ),
                                ),
                              );
                            }),
                            const SizedBox(height: 12),
                          ],

                          const SizedBox(height: 110),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),

      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Transform.translate(
        offset: const Offset(0, kFabYOffset),
        child: SizedBox(
          width: kFabDiameter,
          height: kFabDiameter,
          child: FloatingActionButton(
            heroTag: 'mainFab',
            backgroundColor: const Color.fromRGBO(44, 60, 96, 1),
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            onPressed: _openAddArtistSheet,
            child: const Icon(Icons.add, size: 28),
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
                      icon: Icons.description_outlined,
                      label: 'Scanner',
                      onTap: _uploadAndScan,
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

  // ---------- Misc helpers ----------
  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
}

// ---- Small labeled bottom bar item ----
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

class _Field extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final int maxLines;
  final TextInputType? keyboardType;
  final Widget? prefix;
  final Widget? suffix;
  final IconData? icon;
  final void Function(String)? onChanged;

  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.prefix,
    this.suffix,
    this.icon,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 13,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          onChanged: onChanged,
          style: const TextStyle(color: Colors.black), // <-- text color
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: Colors.black54), // <-- hint color
            filled: true,
            fillColor: Colors.white, // <-- field background
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(
                color: Color(0xFF6C63FF),
                width: 1.4,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 14,
            ),
            prefixIcon: (prefix is Icon)
                ? Padding(
                    padding: const EdgeInsets.only(left: 6, right: 2),
                    child: prefix,
                  )
                : null,
            prefixText: (prefix is Text) ? (prefix as Text).data : null,
            suffixText: (suffix is Text) ? (suffix as Text).data : null,
          ),
        ),
      ],
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final String grossStr;
  final String rateStr;
  final double computed;

  const _PreviewCard({
    required this.grossStr,
    required this.rateStr,
    required this.computed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFF1EEFF),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF6C63FF).withOpacity(0.25)),
      ),
      child: Row(
        children: [
          const Icon(Icons.calculate_outlined),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Your earnings (preview)',
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 2),
                Text(
                  '£${computed.toStringAsFixed(2)}  •  £${(double.tryParse(grossStr) ?? 0).toStringAsFixed(2)} × ${(double.tryParse(rateStr) ?? 0).toStringAsFixed(2)}%',
                  style: const TextStyle(color: Colors.black54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ---- Section card used in the scanner bottom sheet ----
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

// ---------------- Earnings Bar Chart ----------------
class _EarningsBarChart extends StatelessWidget {
  final List<ArtistEarnings> earnings;
  final Widget? headerTrailing; // 👈 new

  const _EarningsBarChart({
    required this.earnings,
    this.headerTrailing, // 👈 new
  });

  // A pleasant palette; extend if you have many artists
  static const List<Color> _palette = [
    Color(0xFF4DA3FF), // blue
    Color(0xFFFF6B6B), // red
    Color(0xFF6DD3A0), // green
    Color(0xFFF7B267), // orange
    Color(0xFFB28DFF), // purple
    Color(0xFFFF8FAB), // pink
    Color(0xFF57C7E3), // teal
    Color(0xFF8ED081), // lime
  ];

  String _short(String name) {
    if (name.isEmpty) return 'Artist';
    return name.length > 9 ? '${name.substring(0, 9)}…' : name;
  }

  @override
  Widget build(BuildContext context) {
    // Empty state
    // Empty state
    // Empty state
    if (earnings.isEmpty) {
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.black12),
          // 👇 square corners
          borderRadius: BorderRadius.zero,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.03),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _CardHeader(title: 'Your earnings by artist'),
            const SizedBox(height: 8),

            // 👇 empty chart with grid + axes
            SizedBox(
              height: 220,
              child: BarChart(
                BarChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (value) =>
                        FlLine(color: const Color(0xFFEAEAF0), strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        reservedSize: 44,
                        showTitles: true,
                        getTitlesWidget: (v, meta) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            '£${v.toInt()}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF707386),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    bottomTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  // 👇 no bars, just empty grid
                  barGroups: const [],
                ),
              ),
            ),

            const SizedBox(height: 12),
            const Text(
              'No earnings yet. Add a revenue source to see this chart.',
              style: TextStyle(color: Colors.black54),
            ),
          ],
        ),
      );
    }

    // Build bars
    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < earnings.length; i++) {
      final v = earnings[i].totalManagerEarnings;
      final color = _palette[i % _palette.length];
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: v,
              width: 18,
              borderRadius: BorderRadius.circular(6),
              rodStackItems: [], // solid color rod
              color: color,
            ),
          ],
        ),
      );
    }

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.black12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(
            title: 'Your earnings by artist',
            trailing: headerTrailing, // 👈 new
          ),

          const SizedBox(height: 8),

          // Chart
          SizedBox(
            height: 220,
            child: BarChart(
              BarChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) =>
                      FlLine(color: const Color(0xFFEAEAF0), strokeWidth: 1),
                ),
                borderData: FlBorderData(show: false),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      reservedSize: 44,
                      showTitles: true,
                      getTitlesWidget: (v, meta) {
                        // format £ with no decimals on ticks
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Text(
                            '£${v.toInt()}',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF707386),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, meta) {
                        final i = v.toInt();
                        if (i < 0 || i >= earnings.length) {
                          return const SizedBox.shrink();
                        }
                        return Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Text(
                            _short(earnings[i].displayName ?? 'Artist'),
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF707386),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                barGroups: barGroups,
                barTouchData: BarTouchData(
                  enabled: true,
                  touchTooltipData: BarTouchTooltipData(
                    tooltipPadding: const EdgeInsets.all(8),
                    tooltipRoundedRadius: 8,
                    tooltipMargin: 6,
                    fitInsideVertically: true,
                    fitInsideHorizontally: true,
                    // remove maxContentWidth if your version complains; it's optional
                    getTooltipItem: (group, groupIndex, rod, rodIndex) {
                      final name =
                          earnings[group.x.toInt()].displayName ?? 'Artist';
                      return BarTooltipItem(
                        '$name\n£${rod.toY.toStringAsFixed(2)}',
                        const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.black,
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(height: 12),

          // Legend
          Wrap(
            spacing: 14,
            runSpacing: 8,
            children: List.generate(earnings.length, (i) {
              final color = _palette[i % _palette.length];
              final name = earnings[i].displayName ?? 'Artist';
              return _LegendDot(color: color, label: name);
            }),
          ),
        ],
      ),
    );
  }
}

// Small header text inside the card, styled like the screenshot
class _CardHeader extends StatelessWidget {
  final String title;
  final Widget? trailing; // 👈 new

  const _CardHeader({required this.title, this.trailing}); // 👈 new

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              letterSpacing: 0.2,
              fontWeight: FontWeight.w800,
              color: Color(0xFF3B3E5A),
            ),
          ),
        ),
        if (trailing != null) trailing!, // 👈 new
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: const TextStyle(
            fontSize: 12,
            color: Color(0xFF707386),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
