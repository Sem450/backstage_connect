// lib/pages/saved_analyses_page.dart
import 'dart:ui' show ImageFilter; // BackdropFilter.blur
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import '../services/contract_service.dart';
import 'saved_analysis_detail_page.dart';

enum _SortMode { recent, az }

class SavedAnalysesPage extends StatefulWidget {
  final List<Map<String, dynamic>> analyses;

  const SavedAnalysesPage({super.key, required this.analyses});

  @override
  State<SavedAnalysesPage> createState() => _SavedAnalysesPageState();
}

class _SavedAnalysesPageState extends State<SavedAnalysesPage> {
  final _contracts = ContractService();
  late List<Map<String, dynamic>> _analyses;
  String _query = '';
  _SortMode _sort = _SortMode.recent;

  @override
  void initState() {
    super.initState();
    _analyses = List<Map<String, dynamic>>.from(widget.analyses);
  }

  String _prettyDate(dynamic iso) {
    if (iso == null) return '';
    try {
      final dt = DateTime.parse(iso.toString()).toLocal();
      return DateFormat.yMMMd().add_jm().format(dt);
    } catch (_) {
      return iso.toString();
    }
  }

  Future<void> _deleteRow(dynamic rawId) async {
    final idStr = rawId.toString();

    final ok = await showCupertinoDialog<bool>(
      context: context,
      builder: (_) => CupertinoAlertDialog(
        title: const Text('Delete analysis?'),
        content: const Text('This cannot be undone.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (ok != true) return;

    try {
      await _contracts.deleteAnalysis(idStr);
      setState(() {
        _analyses.removeWhere((a) => a['id'].toString() == idStr);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Deleted')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  List<Map<String, dynamic>> _filteredSorted() {
    // Filter
    final q = _query.trim().toLowerCase();
    final items = _analyses.where((a) {
      if (q.isEmpty) return true;
      final title = (a['title'] ?? '').toString().toLowerCase();
      final who = (a['for_display_name'] ?? '').toString().toLowerCase();
      return title.contains(q) || who.contains(q);
    }).toList();

    // Sort
    if (_sort == _SortMode.recent) {
      items.sort((a, b) {
        final da = DateTime.tryParse((a['created_at'] ?? '').toString());
        final db = DateTime.tryParse((b['created_at'] ?? '').toString());
        if (da == null && db == null) return 0;
        if (da == null) return 1;
        if (db == null) return -1;
        return db.compareTo(da); // newest first
      });
    } else {
      items.sort((a, b) {
        final ta = (a['title'] ?? '').toString().toLowerCase();
        final tb = (b['title'] ?? '').toString().toLowerCase();
        return ta.compareTo(tb);
      });
    }
    return items;
  }

  // Quick toggle for the sort mode (Recent <-> A–Z)
  void _toggleSortMode() {
    setState(() {
      _sort = _sort == _SortMode.recent ? _SortMode.az : _SortMode.recent;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          _sort == _SortMode.recent ? 'Sorted by Recent' : 'Sorted A–Z',
        ),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 900),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final list = _filteredSorted();

    return Scaffold(
      backgroundColor: const Color(0xFF0D0F15),
      body: CustomScrollView(
        slivers: [
          // ---- Glassy App Bar ----
        SliverAppBar(
  pinned: true,
  floating: true,
  snap: true,
  elevation: 0,
  backgroundColor: Colors.transparent,

  // make back arrow & default icons white
  foregroundColor: Colors.white,                 // <- 1-liner (Flutter 3.7+)
  iconTheme: const IconThemeData(color: Colors.white), // extra safety
  systemOverlayStyle: SystemUiOverlayStyle.light,      // white status bar icons

  // or explicitly set a white back button:
  leading: const BackButton(color: Colors.white),

  toolbarHeight: 56,
  titleSpacing: 12,
  flexibleSpace: ClipRect(
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.05),
          border: Border(
            bottom: BorderSide(color: Colors.white.withOpacity(0.08)),
          ),
        ),
      ),
    ),
  ),
            title: Row(
              children: [
                const Icon(
                  CupertinoIcons.square_list,
                  color: Colors.white70,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Saved Analyses',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                _CountChip(count: list.length),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _toggleSortMode,
                  icon: const Icon(
                    CupertinoIcons.arrow_up_arrow_down,
                    color: Colors.white70,
                    size: 20,
                  ),
                  tooltip: _sort == _SortMode.recent
                      ? 'Sort A–Z'
                      : 'Sort Recent',
                  splashRadius: 20,
                ),
              ],
            ),
          ),

          // ---- Optional overview card (kept as-is) ----
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: _OverviewCard(
                count: list.length,
                sort: _sort,
                onSortChanged: (m) => setState(() => _sort = m),
                onQueryChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),

          if (list.isEmpty)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(),
            )
          else
            SliverList.separated(
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (context, i) {
                final a = list[i];
                final title = (a['title'] ?? 'Untitled contract')
                    .toString()
                    .trim();
                final who = (a['for_display_name'] ?? '').toString().trim();
                final created = _prettyDate(a['created_at']);

                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Dismissible(
                    key: ValueKey('analysis_${a['id']}'),
                    direction: DismissDirection.endToStart,
                    background: _SwipeBg(),
                    confirmDismiss: (_) async {
                      await _deleteRow(a['id']);
                      return false; // manual removal on success
                    },
                    child: _GlassTile(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) =>
                                SavedAnalysisDetailPage(analysisRow: a),
                          ),
                        );
                      },
                      leading: const Icon(CupertinoIcons.doc_text, size: 22),
                      title: title,
                      subtitle: [
                        if (who.isNotEmpty) 'For $who',
                        if (created.isNotEmpty) created,
                      ].join('  •  '),
                      trailing: const Icon(
                        CupertinoIcons.chevron_forward,
                        size: 18,
                      ),
                      onDelete: () => _deleteRow(a['id']),
                    ),
                  ),
                );
              },
            ),

          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }
}

/// Frosted/raised overview card with count, search, and sort control.
class _OverviewCard extends StatelessWidget {
  final int count;
  final _SortMode sort;
  final ValueChanged<_SortMode> onSortChanged;
  final ValueChanged<String> onQueryChanged;

  const _OverviewCard({
    required this.count,
    required this.sort,
    required this.onSortChanged,
    required this.onQueryChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 16,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(
                    CupertinoIcons.square_list,
                    size: 18,
                    color: Colors.white70,
                  ),
                  const SizedBox(width: 8),
                  _CountChip(count: count),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 10),
              CupertinoSearchTextField(
                placeholder: 'Search title or person',
                onChanged: onQueryChanged,
                style: const TextStyle(color: Colors.white),
                placeholderStyle: TextStyle(
                  color: Colors.white.withOpacity(0.6),
                ),
                backgroundColor: Colors.white.withOpacity(0.10),
                prefixIcon: const Icon(
                  CupertinoIcons.search,
                  color: Colors.white70,
                ),
                suffixIcon: const Icon(
                  CupertinoIcons.xmark_circle_fill,
                  color: Colors.white54,
                ),
              ),
              const SizedBox(height: 12),
              _SortControl(sort: sort, onChanged: onSortChanged),
            ],
          ),
        ),
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final int count;
  const _CountChip({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        gradient: const LinearGradient(
          begin: Alignment(-1, -1),
          end: Alignment(1, 1),
          colors: [Color(0xFF8B5CF6), Color(0xFF6C63FF)],
        ),
      ),
      child: Text(
        '$count item${count == 1 ? '' : 's'}',
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w700,
          fontSize: 12,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _SortControl extends StatelessWidget {
  final _SortMode sort;
  final ValueChanged<_SortMode> onChanged;

  const _SortControl({required this.sort, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return CupertinoSlidingSegmentedControl<_SortMode>(
      groupValue: sort,
      backgroundColor: Colors.white.withOpacity(0.10),
      thumbColor: Colors.white.withOpacity(0.22),
      children: const {
        _SortMode.recent: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            'Recent',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
        _SortMode.az: Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            'A–Z',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
          ),
        ),
      },
      onValueChanged: (v) {
        if (v != null) onChanged(v);
      },
    );
  }
}

/// A glassy list row with soft shadow, sized by its content (finite height).
class _GlassTile extends StatelessWidget {
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final Widget leading;
  final String title;
  final String subtitle;
  final Widget trailing;

  const _GlassTile({
    required this.onTap,
    required this.onDelete,
    required this.leading,
    required this.title,
    required this.subtitle,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.25),
                blurRadius: 16,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              splashColor: Colors.white.withOpacity(0.05),
              highlightColor: Colors.white.withOpacity(0.03),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 14,
                ),
                child: Row(
                  children: [
                    IconTheme(
                      data: const IconThemeData(color: Colors.white70),
                      child: leading,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title.isEmpty ? 'Untitled' : title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 16,
                              height: 1.05,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconTheme(
                      data: const IconThemeData(color: Colors.white54),
                      child: trailing,
                    ),
                    const SizedBox(width: 2),
                    IconButton(
                      icon: const Icon(
                        Icons.close,
                        color: Colors.white54,
                        size: 20,
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      onPressed: onDelete,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwipeBg extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: const Color(0xFFB00020),
      ),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: const Icon(CupertinoIcons.delete_solid, color: Colors.white),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          Icon(CupertinoIcons.doc_text_search, color: Colors.white38, size: 44),
          SizedBox(height: 14),
          Text(
            'No saved analyses yet',
            style: TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
              fontSize: 18,
            ),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 6),
          Text(
            'Analyses you save will appear here.\nSearch and sort when needed.',
            style: TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
