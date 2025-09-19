// lib/services/contract_service.dart
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show File;

import 'package:supabase_flutter/supabase_flutter.dart';

class ContractService {
  final SupabaseClient _sb = Supabase.instance.client;

  /// Upload a contract to Storage and return a **signed URL** (30 minutes).
  ///
  /// Bucket: `contracts`
  /// Path:   contracts/<userId>/<timestamp>-<originalName>
  ///
  /// Make sure you created the bucket:
  ///   Storage → Create bucket "contracts" (public OFF).
  /// RLS not used here because we serve via signed URLs.
  Future<String> uploadContract({
    Uint8List? bytes,
    File? file,
    required String originalName,
  }) async {
    final user = _sb.auth.currentUser;
    if (user == null) throw 'You must be signed in.';

    final sanitized = originalName.replaceAll(RegExp(r'[^a-zA-Z0-9_.-]'), '_');
    final path =
        'contracts/${user.id}/${DateTime.now().millisecondsSinceEpoch}-$sanitized';

    // Upload
    if (bytes != null) {
      await _sb.storage.from('contracts').uploadBinary(path, bytes);
    } else if (file != null) {
      await _sb.storage.from('contracts').upload(path, file);
    } else {
      throw 'Provide bytes or file.';
    }

    // Create a signed URL (30 minutes)
    final signed = await _sb.storage
        .from('contracts')
        .createSignedUrl(path, 60 * 30);
    return signed;
  }

  /// Call the Edge Function to analyze the contract by presigned file URL.
  /// Uses the Supabase Functions client (it adds the `Authorization: Bearer <accessToken>` for you).
  Future<Map<String, dynamic>> analyzeByUrl(String fileUrl) async {
    final res = await _sb.functions.invoke(
      'analyze-contract',
      body: {'fileUrl': fileUrl},
    );
    // If the function returned an error JSON with ok=false, surface it
    if (res.data is Map && res.data['ok'] == false) {
      throw res.data['error'] ?? 'Function returned error';
    }
    return (res.data as Map).cast<String, dynamic>();
  }

  /// Save an analysis so you can show it in the "Saved" page later.
  ///
  /// Table schema suggestion:
  ///   create table public.contract_analyses (
  ///     id uuid primary key default gen_random_uuid(),
  ///     owner_id uuid not null references auth.users(id),
  ///     title text not null,
  ///     file_url text not null,
  ///     analysis_json jsonb not null,
  ///     for_user_id uuid,
  ///     for_display_name text,
  ///     created_at timestamptz not null default now()
  ///   );
  ///
  /// RLS:
  ///   enable row level security on contract_analyses;
  ///   create policy "own rows" on contract_analyses
  ///     for all using (auth.uid() = owner_id) with check (auth.uid() = owner_id);
  Future<void> saveAnalysis({
    required String fileUrl,
    required Map<String, dynamic> analysis,
    required String title,
    String? forUserId,
    String? forDisplayName,
  }) async {
    final user = _sb.auth.currentUser;
    if (user == null) throw 'You must be signed in.';

    await _sb.from('contract_analyses').insert({
      'user_id': user.id,
      'title': title,
      'file_url': fileUrl,
      'analysis_json': analysis,
      'for_user_id': forUserId,
      'for_display_name': forDisplayName,
    });
  }

  /// List your saved analyses (newest first).
  Future<List<Map<String, dynamic>>> listSavedAnalyses() async {
    final user = _sb.auth.currentUser;
    if (user == null) throw 'You must be signed in.';

    final rows = await _sb
        .from('contract_analyses')
        .select()
        .eq('user_id', user.id)
        .order('created_at', ascending: false);

    return (rows as List).cast<Map<String, dynamic>>();
  }

  /// Optional: delete a saved analysis.
  Future<void> deleteAnalysis(String id) async {
    await _sb.from('contract_analyses').delete().eq('id', id);
  }
}
