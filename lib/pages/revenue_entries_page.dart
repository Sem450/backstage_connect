import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../models/revenue_entry.dart';
import '../services/revenue_service.dart';

class RevenueEntriesPage extends StatefulWidget {
  final String managerId;
  final String artistId;
  final String artistName;

  const RevenueEntriesPage({
    super.key,
    required this.managerId,
    required this.artistId,
    required this.artistName,
  });

  @override
  State<RevenueEntriesPage> createState() => _RevenueEntriesPageState();
}

class _RevenueEntriesPageState extends State<RevenueEntriesPage> {
  final _revenue = RevenueService();
  late Future<List<RevenueEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _revenue.listEntriesForArtist(
      managerId: widget.managerId,
      artistId: widget.artistId,
    );
  }

  Future<void> _reload() async {
    setState(() {
      _future = _revenue.listEntriesForArtist(
        managerId: widget.managerId,
        artistId: widget.artistId,
      );
    });
  }

  Future<void> _confirmDelete(RevenueEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete revenue?'),
        content: Text(
          '“${e.title}” on ${DateFormat('d MMM yyyy').format(e.occurredOn)} will be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _revenue.deleteEntry(e.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Deleted')));
        _reload();
      }
    }
  }

  Future<void> _editEntry(RevenueEntry e) async {
    final titleC = TextEditingController(text: e.title);
    final grossC = TextEditingController(
      text: e.grossAmount.toStringAsFixed(2),
    );
    final rateC = TextEditingController(
      text: e.commissionRateAtTime == null
          ? ''
          : e.commissionRateAtTime!.toStringAsFixed(2),
    );
    final notesC = TextEditingController(text: e.notes ?? '');
    DateTime when = e.occurredOn; // already a DateTime

    await showModalBottomSheet(
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
          child: SingleChildScrollView(
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
                Text(
                  'Edit “${e.title}”',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 12),
                _Field(
                  label: 'Title',
                  controller: titleC,
                  hint: 'e.g. Spotify Q2',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _Field(
                        label: 'Gross amount',
                        controller: grossC,
                        prefix: const Text('£ '),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _Field(
                        label: 'Commission % (override)',
                        controller: rateC,
                        suffix: const Text('%'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _Field(label: 'Notes', controller: notesC, maxLines: 3),
                const SizedBox(height: 10),
                Row(
                  children: [
                    const Icon(Icons.event_outlined),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Date • ${DateFormat('d MMM yyyy').format(when)}',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: ctx,
                          initialDate: when,
                          firstDate: DateTime(2015),
                          lastDate: DateTime.now().add(
                            const Duration(days: 365 * 5),
                          ),
                        );
                        if (picked != null) {
                          when = picked;
                          (ctx as Element).markNeedsBuild();
                        }
                      },
                      child: const Text('Change'),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      final title = titleC.text.trim();
                      final gross = double.tryParse(grossC.text.trim());
                      final rate = rateC.text.trim().isEmpty
                          ? null
                          : double.tryParse(rateC.text.trim());
                      final notes = notesC.text.trim();

                      if (title.isEmpty) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Title required')),
                        );
                        return;
                      }
                      if (gross == null || gross < 0) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Invalid gross')),
                        );
                        return;
                      }
                      try {
                        await _revenue.updateRevenueEntry(
                          revenueEntryId: e.id,
                          title: title,
                          grossAmount: gross,
                          occurredOn: when,
                          commissionRateOverride: rate,
                          notes: notes,
                        );
                        if (mounted) Navigator.pop(ctx);
                        _reload();
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Saved')),
                          );
                        }
                      } catch (err) {
                        ScaffoldMessenger.of(
                          context,
                        ).showSnackBar(SnackBar(content: Text('Error: $err')));
                      }
                    },
                    icon: const Icon(Icons.save),
                    label: const Text('Save changes'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF6C63FF),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        systemOverlayStyle: SystemUiOverlayStyle.dark,
        backgroundColor: Colors.white,
        elevation: 0.5,
        surfaceTintColor: Colors.transparent,
        foregroundColor: const Color(0xFF111827),
        title: Text(
          'Revenue • ${widget.artistName}',
          style: const TextStyle(
            color: Color(0xFF111827),
            fontWeight: FontWeight.w700,
          ),
        ),
        iconTheme: const IconThemeData(color: Color(0xFF111827)),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: FutureBuilder<List<RevenueEntry>>(
          future: _future,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(child: Text('Error: ${snap.error}'));
            }
            final items = snap.data ?? [];
            if (items.isEmpty) {
              return const Center(child: Text('No revenue yet.'));
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
              itemBuilder: (_, i) {
                final e = items[i];
                return Card(
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    title: Text(
                      e.title,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    subtitle: Text(
                      '${DateFormat('d MMM yyyy').format(e.occurredOn)} • Gross £${e.grossAmount.toStringAsFixed(2)}'
                      '${e.commissionRateAtTime != null ? ' • ${e.commissionRateAtTime!.toStringAsFixed(2)}% fee' : ''}',
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              '£${e.managerEarnings.toStringAsFixed(2)}',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Text(
                              'Your cut',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.black54,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 6),
                        IconButton(
                          tooltip: 'Delete',
                          icon: const Icon(
                            Icons.close_rounded,
                          ),
                          color: Colors.redAccent,
                          onPressed: () => _confirmDelete(e),
                        ),
                      ],
                    ),
                    onTap: () => _editEntry(e),
                    onLongPress: () => _confirmDelete(e),
                  ),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemCount: items.length,
            );
          },
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final Widget? prefix;
  final Widget? suffix;

  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.prefix,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            hintText: hint,
            filled: true,
            fillColor: const Color(0xFFF7F7FB),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 12,
            ),
            prefixIcon: prefix is Icon
                ? Padding(
                    padding: const EdgeInsets.only(left: 6, right: 2),
                    child: prefix,
                  )
                : null,
            prefixText: prefix is Text ? (prefix as Text).data : null,
            suffixText: suffix is Text ? (suffix as Text).data : null,
          ),
        ),
      ],
    );
  }
}
