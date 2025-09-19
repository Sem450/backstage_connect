// lib/services/auth_service.dart
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show kIsWeb; // for web redirect
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/app_user.dart';

final supa = Supabase.instance.client;

class AuthService {
  // ---------- PROFILE ----------

  Future<AppUser?> currentProfile() async {
    final user = supa.auth.currentUser;
    if (user == null) return null;

    final res = await supa
        .from('profiles')
        .select('id,email,display_name,role,unique_code,avatar_url')
        .eq('id', user.id)
        .single();

    return AppUser.fromMap(res);
  }

  Future<void> updateDisplayName(String name) async {
    final uid = supa.auth.currentUser?.id;
    if (uid == null) throw Exception('Not signed in');
    await supa.from('profiles').update({'display_name': name}).eq('id', uid);
  }

  /// Update only the role (use on the profile setup page).
  Future<void> updateRole({required String role}) async {
    final uid = supa.auth.currentUser?.id;
    if (uid == null) throw Exception('Not signed in');
    await supa.from('profiles').update({'role': role}).eq('id', uid);
  }

  /// Optional convenience: update any combo of fields.
  Future<void> updateProfile({
    String? displayName,
    String? role,
    String? avatarUrl,
  }) async {
    final uid = supa.auth.currentUser?.id;
    if (uid == null) throw Exception('Not signed in');

    await supa.from('profiles').upsert({
      'id': uid,
      if (displayName != null) 'display_name': displayName,
      if (role != null) 'role': role,
      if (avatarUrl != null) 'avatar_url': avatarUrl,
    });
  }

  /// Upload avatar bytes to Storage and save a cache-busted public URL.
  /// Requires Storage bucket `avatars` (public, or sign URLs yourself).
  Future<void> updateAvatarFromBytes(
    Uint8List bytes, {
    String ext = 'jpg',
  }) async {
    final uid = supa.auth.currentUser?.id;
    if (uid == null) throw Exception('Not signed in');

    final path = 'users/$uid/avatar.${ext.toLowerCase()}';

    await supa.storage.from('avatars').uploadBinary(
          path,
          bytes,
          fileOptions: FileOptions(
            upsert: true,
            contentType: ext.toLowerCase() == 'png' ? 'image/png' : 'image/jpeg',
          ),
    );

    final base = supa.storage.from('avatars').getPublicUrl(path);
    final busted = '$base?v=${DateTime.now().millisecondsSinceEpoch}';
    await supa.from('profiles').update({'avatar_url': busted}).eq('id', uid);
  }

  /// Convenience: read my role from profiles
  Future<String?> myRole() async {
    final u = supa.auth.currentUser;
    if (u == null) return null;

    final row = await supa
        .from('profiles')
        .select('role')
        .eq('id', u.id)
        .single();

    return (row['role'] as String?)?.trim();
  }

  // ---------- AUTH ----------

  /// SIGN UP (step 1): create auth user + seed profile row.
  /// `role` is optional; default to 'pending' to satisfy DB constraint.
  Future<AppUser> signUp({
    required String email,
    required String password,
    String? role,
    String? displayName,
  }) async {
    final authRes = await supa.auth.signUp(email: email, password: password);
    final uid = authRes.user?.id;
    if (uid == null) {
      throw Exception('Check your email to confirm your account, then log in.');
    }

    final profileRow = await supa
        .from('profiles')
        .upsert({
          'id': uid,
          'email': email,
          'role': role ?? 'pending',
          if (displayName != null && displayName.trim().isNotEmpty)
            'display_name': displayName.trim(),
        }, onConflict: 'id')
        .select('id,email,display_name,role,unique_code,avatar_url')
        .single();

    return AppUser.fromMap(profileRow);
  }

  Future<AppUser> login({
    required String email,
    required String password,
  }) async {
    await supa.auth.signInWithPassword(email: email, password: password);
    final user = supa.auth.currentUser!;

    final map = await supa
        .from('profiles')
        .select('id,email,display_name,role,unique_code,avatar_url')
        .eq('id', user.id)
        .single();

    return AppUser.fromMap(map);
  }

  Future<void> signOut() => supa.auth.signOut();

  // ---------- PASSWORD RESET ----------

  /// Sends a reset link. Make sure the redirect is whitelisted in
  /// Supabase → Authentication → URL Configuration.
  ///
  /// Web (Chrome dev): we use the current origin so the port always matches,
  /// and route to your app’s /reset-callback page (GoRouter).
  /// Mobile: replace with your app scheme once you add deep links.
  Future<void> sendPasswordResetEmail(String email) async {
    final redirect = kIsWeb
        ? '${Uri.base.origin}/#/reset-callback'
        : 'com.backstage.app://reset-callback';

    await supa.auth.resetPasswordForEmail(email, redirectTo: redirect);
  }

  /// Call this on your ResetPasswordPage after the user enters a new password.
  Future<void> updatePassword(String newPassword) async {
    await supa.auth.updateUser(UserAttributes(password: newPassword));
  }

  // ---------- CONNECTIONS ----------

  /// Manager: send a request to an artist by their unique code
  Future<void> sendRequestByArtistCode(String code) async {
    final me = supa.auth.currentUser!;
    final clean = code.trim().toLowerCase();

    final artist = await supa
        .rpc('find_artist_by_code', params: {'code': clean})
        .maybeSingle();

    if (artist == null) throw Exception('No artist found for that code.');
    if (artist['id'] == me.id) throw Exception('You cannot add yourself.');

    await supa.from('connection_requests').insert({
      'manager_id': me.id,
      'artist_id': artist['id'],
      'status': 'pending',
    });
  }

  /// Artist: list pending requests (manager_id + request id)
  Future<List<Map<String, dynamic>>> pendingRequestsForArtist() async {
    final me = supa.auth.currentUser!;

    final rows = await supa
        .from('connection_requests')
        .select('id, manager_id, created_at')
        .eq('artist_id', me.id)
        .eq('status', 'pending')
        .order('created_at');

    final mgrIds = (rows as List)
        .map((r) => r['manager_id'] as String)
        .toSet()
        .toList();

    final mgrProfiles = await _profilesByIds(mgrIds);
    final mapById = {for (final p in mgrProfiles) p['id'] as String: p};

    return rows.map<Map<String, dynamic>>((r) {
      return {
        'id': r['id'],
        'manager_id': r['manager_id'],
        'created_at': r['created_at'],
        'manager_profile': mapById[r['manager_id']],
      };
    }).toList();
  }

  /// Artist: accept / reject request (always return or throw)
  Future<Map<String, dynamic>> respondToRequest(
    int requestId,
    bool accept,
  ) async {
    final updated = await supa
        .from('connection_requests')
        .update({'status': accept ? 'accepted' : 'rejected'})
        .eq('id', requestId)
        .select()
        .maybeSingle();

    if (updated == null) {
      throw StateError(
        'No matching request (id=$requestId) or permission denied.',
      );
    }

    return Map<String, dynamic>.from(updated);
  }

  /// Manager: list accepted artists (their profiles)
  Future<List<Map<String, dynamic>>> managedArtists() async {
    final me = supa.auth.currentUser!;

    final rows = await supa
        .from('manager_artists')
        .select('artist_id, created_at')
        .eq('manager_id', me.id)
        .order('created_at');

    final ids = (rows as List).map((r) => r['artist_id'] as String).toList();
    if (ids.isEmpty) return [];

    final artists = await _profilesByIds(ids);
    final byId = {for (final a in artists) a['id'] as String: a};

    return rows.map<Map<String, dynamic>>((r) {
      return {
        'artist_id': r['artist_id'],
        'created_at': r['created_at'],
        'artist_profile': byId[r['artist_id']],
      };
    }).toList();
  }

  /// Manager: see outgoing requests (pending)
  Future<List<Map<String, dynamic>>> outgoingRequestsPending() async {
    final me = supa.auth.currentUser!;

    final rows = await supa
        .from('connection_requests')
        .select('id, artist_id, created_at, status')
        .eq('manager_id', me.id)
        .eq('status', 'pending')
        .order('created_at');

    final ids = (rows as List).map((r) => r['artist_id'] as String).toList();
    final artists = await _profilesByIds(ids);
    final byId = {for (final a in artists) a['id'] as String: a};

    return rows.map<Map<String, dynamic>>((r) {
      return {
        'id': r['id'],
        'artist_id': r['artist_id'],
        'created_at': r['created_at'],
        'artist_profile': byId[r['artist_id']],
      };
    }).toList();
  }

  /// Artist: list my managers
  Future<List<Map<String, dynamic>>> myManagers() async {
    final uid = supa.auth.currentUser!.id;

    final rels = await supa
        .from('manager_artists')
        .select('manager_id, created_at')
        .eq('artist_id', uid)
        .order('created_at');

    final rows = (rels as List).cast<Map<String, dynamic>>();
    if (rows.isEmpty) return [];

    final ids = rows.map((r) => r['manager_id'] as String).toList();
    final profs = await _profilesByIds(ids);
    final byId = {for (final p in profs) p['id'] as String: p};

    return rows.map<Map<String, dynamic>>((r) {
      final mid = r['manager_id'] as String;
      return {
        'manager_id': mid,
        'created_at': r['created_at'],
        'manager_profile': byId[mid] ?? {},
      };
    }).toList();
  }

  // ---------- helpers ----------

  Future<List<Map<String, dynamic>>> _profilesByIds(List<String> ids) async {
    if (ids.isEmpty) return [];
    return await supa
        .from('profiles')
        .select('id,email,display_name,role,unique_code,avatar_url')
        .inFilter('id', ids);
  }
}
