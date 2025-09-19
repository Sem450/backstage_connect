class RevenueEntry {
  final String id;
  final String managerId;
  final String artistId;
  final String title;
  final DateTime occurredOn;
  final double grossAmount;
  final double commissionRateAtTime; // percent
  final double managerEarnings;
  final String? notes;

  RevenueEntry({
    required this.id,
    required this.managerId,
    required this.artistId,
    required this.title,
    required this.occurredOn,
    required this.grossAmount,
    required this.commissionRateAtTime,
    required this.managerEarnings,
    this.notes,
  });

  factory RevenueEntry.fromMap(Map<String, dynamic> m) {
    return RevenueEntry(
      id: m['id'] as String,
      managerId: m['manager_id'] as String,
      artistId: m['artist_id'] as String,
      title: m['title'] as String,
      occurredOn: DateTime.parse(m['occurred_on'] as String),
      grossAmount: (m['gross_amount'] as num).toDouble(),
      commissionRateAtTime: (m['commission_rate_at_time'] as num).toDouble(),
      managerEarnings: (m['manager_earnings'] as num).toDouble(),
      notes: m['notes'] as String?,
    );
  }
}

class ArtistEarnings {
  final String artistId;
  final double totalManagerEarnings;
  final String? displayName;
  final String? avatarUrl;

  ArtistEarnings({
    required this.artistId,
    required this.totalManagerEarnings,
    this.displayName,
    this.avatarUrl,
  });
}
