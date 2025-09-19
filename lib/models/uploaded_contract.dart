// lib/models/uploaded_contract.dart
// lib/models/uploaded_contract.dart

class UploadedContract {
  final String fileUrl;
  final String originalName;
  final DateTime createdAt;

  UploadedContract({
    required this.fileUrl,
    required this.originalName,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'file_url': fileUrl,
        'original_name': originalName,
        'created_at': createdAt.toIso8601String(),
      };

  factory UploadedContract.fromJson(Map<String, dynamic> json) {
    return UploadedContract(
      fileUrl: json['file_url'] as String,
      originalName: json['original_name'] as String? ?? 'Contract',
      createdAt: DateTime.tryParse(json['created_at'] ?? '') ?? DateTime.now(),
    );
  }
}
