class AppUser {
  final String id;
  final String email;
  final String? displayName;
  final String role;
  final String uniqueCode;
  final String? avatarUrl;

  AppUser({
    required this.id,
    required this.email,
    required this.role,
    required this.uniqueCode,
    this.displayName,
    this.avatarUrl,
  });

  factory AppUser.fromMap(Map<String, dynamic> m) => AppUser(
    id: m['id'] as String,
    email: m['email'] as String,
    displayName: m['display_name'] as String?,
    role: m['role'] as String,
    uniqueCode: m['unique_code'] as String,
    avatarUrl: m['avatar_url'] as String?, // ✅ use m not map
  );
}
