import 'dart:convert';
import 'dart:io' show File; // OK on mobile; not used on web path
import 'dart:typed_data';
import 'dart:ui';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart' as pp;

import '../services/auth_service.dart';

class AvatarSetupPage extends StatefulWidget {
  const AvatarSetupPage({super.key});

  @override
  State<AvatarSetupPage> createState() => _AvatarSetupPageState();
}

class _AvatarSetupPageState extends State<AvatarSetupPage> {
  final _auth = AuthService();

  Uint8List? _bytes; // cropped image data for preview + upload
  String _ext = 'jpg'; // 'jpg' or 'png'
  bool _saving = false;
  String? _error;

  // --- Helpers (mobile/desktop only) ---
  Future<String> _writeTempAndGetPath(Uint8List bytes, String ext) async {
    final dir = await pp.getTemporaryDirectory();
    final path =
        '${dir.path}/pick_${DateTime.now().millisecondsSinceEpoch}.$ext';
    final f = File(path);
    await f.writeAsBytes(bytes, flush: true);
    return path;
  }

  // --- Crop bytes on any platform ---
  Future<Uint8List?> _cropBytes(Uint8List bytes, String ext) async {
    // On web, skip cropping to avoid plugin issues
    if (kIsWeb) return bytes;

    // Mobile / desktop crop
    final isPng = ext.toLowerCase() == 'png';
    final path = await pp.getTemporaryDirectory().then(
      (d) =>
          '${d.path}/pick_${DateTime.now().millisecondsSinceEpoch}.${isPng ? 'png' : 'jpg'}',
    );
    await File(path).writeAsBytes(bytes, flush: true);

    final cropped = await ImageCropper().cropImage(
      sourcePath: path,
      compressFormat: isPng ? ImageCompressFormat.png : ImageCompressFormat.jpg,
      compressQuality: 95,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'Crop avatar',
          toolbarColor: const Color(0xFF8B5CF6),
          toolbarWidgetColor: Colors.white,
          lockAspectRatio: true,
        ),
        IOSUiSettings(title: 'Crop avatar', aspectRatioLockEnabled: true),
      ],
    );

    if (cropped == null) return null;
    return await cropped.readAsBytes();
  }

  // --- Pick + crop ---
  Future<void> _pick() async {
    setState(() => _error = null);

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
      withData: true, // ask for in-memory bytes when possible
    );
    if (picked == null) return;

    final f = picked.files.single;

    Uint8List? raw = f.bytes;
    if (raw == null && !kIsWeb && f.path != null) {
      // On mobile/desktop, fall back to reading from path
      try {
        raw = await File(f.path!).readAsBytes();
      } catch (_) {}
    }
    if (raw == null) {
      setState(() => _error = 'Could not read file.');
      return;
    }

    final name = (f.name.isNotEmpty ? f.name : (f.path ?? '')).toLowerCase();
    final ext = name.endsWith('.png') ? 'png' : 'jpg';

    final cropped = await _cropBytes(raw, ext);
    if (cropped == null) return; // user canceled

    setState(() {
      _bytes = cropped;
      _ext = ext;
    });
  }

  Future<void> _save() async {
    if (_bytes == null) {
      setState(() => _error = 'Please choose an image first.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _auth.updateAvatarFromBytes(_bytes!, ext: _ext);
      final role = await _auth.myRole();
      if (!mounted) return;
      context.go(role == 'artist' ? '/artist' : '/manager');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _skip() async {
    final role = await _auth.myRole();
    if (!mounted) return;
    context.go(role == 'artist' ? '/artist' : '/manager');
  }

  // --- UI ---
  @override
  Widget build(BuildContext context) {
    final kb = MediaQuery.of(context).viewInsets.bottom; // keyboard height

    return Scaffold(
      // ensure the scaffold shifts content when keyboard shows
      resizeToAvoidBottomInset: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2A1D49), Color(0xFF171026)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(16, 24, 16, (kb > 0 ? kb : 24) + 8),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(22),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                    child: Container(
                      width: double.infinity, // let it grow to maxWidth
                      padding: const EdgeInsets.symmetric(
                        horizontal: 22,
                        vertical: 24,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.12),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Pick a profile picture',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(height: 12),

                          // Avatar (unchanged)
                          GestureDetector(
                            onTap: _pick,
                            child: Container(
                              width: 140,
                              height: 140,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: const Color(0xFF2A1D49),
                                border: Border.all(color: Colors.white24),
                                image: _bytes == null
                                    ? null
                                    : DecorationImage(
                                        image: MemoryImage(_bytes!),
                                        fit: BoxFit.cover,
                                      ),
                              ),
                              child: _bytes == null
                                  ? const Icon(
                                      Icons.add_a_photo_outlined,
                                      color: Colors.white70,
                                      size: 36,
                                    )
                                  : null,
                            ),
                          ),

                          const SizedBox(height: 14),
                          TextButton.icon(
                            onPressed: _pick,
                            icon: const Icon(
                              Icons.photo_library_outlined,
                              color: Colors.white,
                            ),
                            label: const Text(
                              'Choose / Crop',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                          const SizedBox(height: 8),
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          const SizedBox(height: 6),

                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                shape: const StadiumBorder(),
                                backgroundColor: const Color(0xFF8B5CF6),
                              ),
                              onPressed: _saving ? null : _save,
                              child: _saving
                                  ? const CircularProgressIndicator(
                                      color: Colors.white,
                                    )
                                  : const Text(
                                      'Save & continue',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: _saving ? null : _skip,
                            child: const Text(
                              'Skip for now',
                              style: TextStyle(color: Colors.white70),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
