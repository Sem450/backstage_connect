import 'package:flutter/foundation.dart'; // 👈 for debugPrint
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/revenue_entry.dart';

class RevenueService {
  final SupabaseClient _supabase = Supabase.instance.client;

  // ---------- Defaults (commission %) ----------

  /// Read the default commission rate (%) for a manager/artist pair.
  Future<double?> getDefaultCommissionRate({
    required String managerId,
    required String artistId,
  }) async {
    final row = await _supabase
        .from('manager_artist_settings')
        .select('default_commission_rate')
        .eq('manager_id', managerId)
        .eq('artist_id', artistId)
        .maybeSingle();

    if (row == null) return null;
    final v = row['default_commission_rate'];
    return v == null ? null : (v as num).toDouble();
  }

  /// Upsert the default commission rate (%) for a manager/artist pair.
  Future<void> setDefaultCommissionRate({
    required String managerId,
    required String artistId,
    required double ratePercent,
  }) async {
    await _supabase.from('manager_artist_settings').upsert({
      'manager_id': managerId,
      'artist_id': artistId,
      'default_commission_rate': ratePercent,
    });
    debugPrint(
      '[RevenueService] set default commission '
      'manager=$managerId artist=$artistId rate=$ratePercent%',
    );
  }

  // ---------- Entries CRUD ----------

  /// Insert a revenue entry.
  Future<RevenueEntry> addRevenueEntry({
    required String managerId,
    required String artistId,
    required String title,
    required double grossAmount,
    DateTime? occurredOn,
    double? commissionRateOverride,
    String? notes,
  }) async {
    final payload = <String, dynamic>{
      'manager_id': managerId,
      'artist_id': artistId,
      'title': title,
      'gross_amount': grossAmount,
      'occurred_on': (occurredOn ?? DateTime.now())
          .toIso8601String()
          .split('T')
          .first,
      if (commissionRateOverride != null)
        'commission_rate_at_time': commissionRateOverride,
      if (notes != null && notes.trim().isNotEmpty) 'notes': notes,
    };

    final inserted = await _supabase
        .from('revenue_entries')
        .insert(payload)
        .select()
        .single();

    debugPrint(
      '[RevenueService] inserted revenue id=${inserted['id']} '
      'gross=${inserted['gross_amount']} '
      'rate=${inserted['commission_rate_at_time']} '
      'occurred_on=${inserted['occurred_on']}',
    );

    return RevenueEntry.fromMap(inserted);
  }

  Future<List<RevenueEntry>> listEntriesForArtist({
    required String managerId,
    required String artistId,
  }) async {
    final rows = await _supabase
        .from('revenue_entries')
        .select()
        .eq('manager_id', managerId)
        .eq('artist_id', artistId)
        .order('occurred_on', ascending: false);

    return (rows as List)
        .map((r) => RevenueEntry.fromMap(r as Map<String, dynamic>))
        .toList();
  }

  Future<void> deleteEntry(String revenueEntryId) async {
    await _supabase.from('revenue_entries').delete().eq('id', revenueEntryId);
    debugPrint('[RevenueService] deleted revenue id=$revenueEntryId');
  }

  // ---------- Aggregations (totals) ----------

  Future<List<ArtistEarnings>> totalsByArtist(String managerId) async {
    final rows = await _supabase
        .from('manager_earnings_by_artist')
        .select('''
          artist_id,
          manager_id,
          total_manager_earnings,
          artist:profiles!revenue_entries_artist_id_fkey (
            id, display_name, avatar_url
          )
        ''')
        .eq('manager_id', managerId)
        .order('total_manager_earnings', ascending: false);

    debugPrint('[RevenueService] totalsByArtist fetched ${rows.length} rows');

    return (rows as List).map((r) {
      final artist = r['artist'] as Map<String, dynamic>?;
      return ArtistEarnings(
        artistId: (r['artist_id'] ?? '') as String,
        displayName: artist?['display_name'] as String?,
        avatarUrl: artist?['avatar_url'] as String?,
        totalManagerEarnings:
            (r['total_manager_earnings'] as num?)?.toDouble() ?? 0.0,
      );
    }).toList();
  }

    /// Update a revenue entry (title/gross/date/commission override/notes).
  Future<RevenueEntry> updateRevenueEntry({
    required String revenueEntryId,
    String? title,
    double? grossAmount,
    DateTime? occurredOn,
    double? commissionRateOverride, // pass null to clear; omit to keep
    String? notes,                  // pass '' or null to clear; omit to keep
  }) async {
    final Map<String, dynamic> patch = {};

    if (title != null) patch['title'] = title;
    if (grossAmount != null) patch['gross_amount'] = grossAmount;
    if (occurredOn != null) {
      patch['occurred_on'] = occurredOn.toIso8601String().split('T').first; // DATE
    }

    if (commissionRateOverride != null) {
      patch['commission_rate_at_time'] = commissionRateOverride;
    } else if (commissionRateOverride == null && patch.containsKey('commission_rate_at_time')) {
      // noop — only clear if you explicitly want to. If you DO want to clear, pass double.nan:
    }

    if (notes != null) {
      // allow explicit clearing
      patch['notes'] = notes.trim().isEmpty ? null : notes.trim();
    }

    final updated = await _supabase
        .from('revenue_entries')
        .update(patch)
        .eq('id', revenueEntryId)
        .select()
        .single();

    return RevenueEntry.fromMap(updated);
  }


  Future<List<ArtistEarnings>> totalsByArtistInRange(
    String managerId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final sel = _supabase
        .from('revenue_entries')
        .select('artist_id,gross_amount,commission_rate_at_time,occurred_on')
        .eq('manager_id', managerId);

    if (from != null) sel.gte('occurred_on', _dateStr(from));
    if (to != null) sel.lte('occurred_on', _dateStr(to));

    final List rows = await sel;
    debugPrint(
      '[RevenueService] range rows=${rows.length} '
      '(manager=$managerId, from=${from != null ? _dateStr(from) : '-'}, '
      'to=${to != null ? _dateStr(to) : '-'})',
    );

    final artistIds = <String>{
      for (final r in rows) (r['artist_id'] ?? '').toString(),
    }..removeWhere((id) => id.isEmpty);

    Map<String, double> defaultRateByArtist = {};
    if (artistIds.isNotEmpty) {
      final List defaults = await _supabase
          .from('manager_artist_settings')
          .select('artist_id,default_commission_rate')
          .eq('manager_id', managerId)
          .inFilter('artist_id', artistIds.toList());

      for (final d in defaults) {
        final aid = (d['artist_id'] ?? '').toString();
        final v = (d['default_commission_rate'] as num?)?.toDouble();
        if (aid.isNotEmpty && v != null) defaultRateByArtist[aid] = v;
      }
      debugPrint(
        '[RevenueService] defaults loaded=${defaultRateByArtist.length} '
        'for artists=${artistIds.length}',
      );
    }

    final totals = <String, double>{};
    int nullOverrideCount = 0;

    for (final r in rows) {
      final artistId = (r['artist_id'] ?? '').toString();
      if (artistId.isEmpty) continue;

      final gross = (r['gross_amount'] as num?)?.toDouble() ?? 0.0;
      double? rate = (r['commission_rate_at_time'] as num?)?.toDouble();
      if (rate == null) {
        nullOverrideCount++;
        rate = defaultRateByArtist[artistId];
      }

      final managerE = (rate == null) ? 0.0 : gross * (rate / 100.0);
      totals.update(artistId, (v) => v + managerE, ifAbsent: () => managerE);
    }

    debugPrint(
      '[RevenueService] totals artists=${totals.length} '
      'nullOverrides=$nullOverrideCount '
      'sum=£${totals.values.fold<double>(0, (a, b) => a + b).toStringAsFixed(2)}',
    );

    if (totals.isEmpty) return [];

    debugPrint(
      '[RevenueService] fetching profiles for ${totals.keys.length} artists',
    );
    final List profRows = await _supabase
        .from('profiles')
        .select('id,display_name,avatar_url')
        .inFilter('id', totals.keys.toList());
    debugPrint('[RevenueService] profiles fetched=${profRows.length}');

    final profById = {
      for (final p in profRows)
        (p['id'] as String): Map<String, dynamic>.from(p),
    };

    final list = totals.keys.map((id) {
      final p = profById[id];
      return ArtistEarnings(
        artistId: id,
        totalManagerEarnings: totals[id] ?? 0.0,
        displayName: p?['display_name'] as String?,
        avatarUrl: p?['avatar_url'] as String?,
      );
    }).toList();

    list.sort(
      (a, b) => b.totalManagerEarnings.compareTo(a.totalManagerEarnings),
    );
    return list;
  }

  // ---------- Helpers ----------
  String _dateStr(DateTime d) => d.toIso8601String().split('T').first;
}
