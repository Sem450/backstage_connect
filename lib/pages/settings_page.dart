import 'dart:typed_data';
import 'dart:io' show File; // Used only on Android/iOS when cropping
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:go_router/go_router.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:path_provider/path_provider.dart' as pp;

import '../models/app_user.dart';
import '../services/auth_service.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  // ---- Layout knobs (match dashboard chrome) ----
  static const double kFabDiameter = 52;
  static const double kFabYOffset = 30;
  static const double kFabGapWidth = 80;
  static const double kBarHeight = 64;
  static const Color _accent = Color(0xFF6C63FF);

  final _auth = AuthService();

  AppUser? _me;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  // NEW: local preview when user picks a new avatar
  Uint8List? _previewBytes;
  String _previewExt = 'jpg';

  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _me = await _auth.currentProfile();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Only crop on Android/iOS
  bool get _canCrop =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<Uint8List?> _cropBytes(Uint8List bytes, String ext) async {
    if (!_canCrop) return bytes; // skip on web/desktop

    final isPng = ext.toLowerCase() == 'png';
    final dir = await pp.getTemporaryDirectory();
    final path =
        '${dir.path}/pick_${DateTime.now().millisecondsSinceEpoch}.${isPng ? 'png' : 'jpg'}';
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

  Future<void> _pickAndUpload() async {
    setState(() => _error = null);

    final picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['jpg', 'jpeg', 'png'],
      withData: true,
    );
    if (picked == null) return;

    final f = picked.files.single;

    Uint8List? raw = f.bytes;
    // On mobile/desktop, if no in-memory bytes were provided, fall back to reading from path
    if (raw == null && !_canCrop && f.bytes == null) {
      if (f.path != null) {
        try {
          raw = await File(f.path!).readAsBytes();
        } catch (_) {}
      }
    }
    if (raw == null) {
      setState(() => _error = 'Could not read file.');
      return;
    }

    final name = (f.name.isNotEmpty ? f.name : (f.path ?? '')).toLowerCase();
    final ext = name.endsWith('.png') ? 'png' : 'jpg';

    final cropped = await _cropBytes(raw, ext);
    if (cropped == null) return; // user cancelled crop

    // show local preview immediately
    setState(() {
      _previewBytes = cropped;
      _previewExt = ext;
    });

    // upload
    setState(() => _saving = true);
    try {
      await _auth.updateAvatarFromBytes(cropped, ext: ext);
      await _load(); // refresh profile (pulls avatar_url with cache-buster)
      if (mounted) {
        _changed = true;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile picture updated')),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyCode() async {
    final code = _me?.uniqueCode ?? '';
    if (code.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Code copied')));
  }

  Future<void> _logout() async {
    await _auth.signOut();
    if (!mounted) return;
    context.go('/login');
  }

  Widget _avatarWidget(double size) {
    final initials = (() {
      final dn = (_me?.displayName ?? '').trim();
      if (dn.isNotEmpty) return dn[0].toUpperCase();
      final em = (_me?.email ?? '');
      return em.isNotEmpty ? em[0].toUpperCase() : 'U';
    })();

    if (_previewBytes != null) {
      return ClipOval(
        child: Image.memory(
          _previewBytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
    }

    final url = (_me?.avatarUrl ?? '').trim();
    if (url.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          url,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => CircleAvatar(
            radius: size / 2,
            backgroundColor: _accent,
            child: Text(initials, style: const TextStyle(color: Colors.white)),
          ),
        ),
      );
    }

    return CircleAvatar(
      radius: size / 2,
      backgroundColor: _accent,
      child: Text(initials, style: const TextStyle(color: Colors.white)),
    );
  }

  // ---- Bottom bar item (same style as dashboards) ----
  Widget _bottomItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
  }) {
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
            Icon(icon, size: 27, color: iconColor),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
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

  // ---- Pretty section card ----
  Widget _card({required Widget child, EdgeInsets? padding}) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: padding ?? const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE9E9EF)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 14,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Subtle gradient background to match the rest of the app
    final bgTop = const Color(0xFFF4F5FB);
    final bgBottom = const Color(0xFFEFF1FA);

    return Scaffold(
      backgroundColor: bgTop,
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color.fromARGB(255, 63, 82, 126),
        foregroundColor: Colors.white,
        title: const Text('Settings'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.pop(_changed),
        ),
      ),

      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [bgTop, bgBottom],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Profile header card
                          _card(
                            padding: const EdgeInsets.fromLTRB(16, 18, 16, 18),
                            child: Row(
                              children: [
                                _avatarWidget(72),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        (_me?.displayName?.trim().isNotEmpty ==
                                                true)
                                            ? _me!.displayName!
                                            : (_me?.email ?? 'User'),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: Color(0xFF1F1F1F),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        _me?.email ?? '',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: Colors.black54,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                ElevatedButton.icon(
                                  onPressed: _saving ? null : _pickAndUpload,
                                  icon: const Icon(
                                    Icons.photo_library_outlined,
                                  ),
                                  label: const Text('Change'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFF2ECFF),
                                    foregroundColor: _accent,
                                    elevation: 0,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          if (_error != null)
                            _card(
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),

                          // Unique code card
                          _card(
                            child: Row(
                              children: [
                                const Icon(Icons.vpn_key_outlined),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      const Text(
                                        'Your unique code',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                          color: Color(0xFF3B3E5A),
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      SelectableText(
                                        _me?.uniqueCode ?? '—',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: _copyCode,
                                  icon: const Icon(
                                    Icons.copy_rounded,
                                    size: 18,
                                  ),
                                  label: const Text('Copy'),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 12,
                                    ),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Account actions
                          _card(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Account',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF3B3E5A),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: const Icon(Icons.logout),
                                  title: const Text('Logout'),
                                  subtitle: const Text('Sign out of Backstage'),
                                  trailing: ElevatedButton(
                                    onPressed: _saving ? null : _logout,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFFFF5C5C),
                                      foregroundColor: Colors.white,
                                      elevation: 0,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text('Logout'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
      ),

      // Keep the “little bottoms”: center FAB + bottom nav bar (same style)
      floatingActionButtonLocation: FloatingActionButtonLocation.centerDocked,
      floatingActionButton: Transform.translate(
        offset: const Offset(0, kFabYOffset),
        child: SizedBox(
          width: kFabDiameter,
          height: kFabDiameter,
          child: FloatingActionButton(
            heroTag: 'settingsFab',
            backgroundColor: const Color.fromRGBO(44, 60, 96, 1),
            foregroundColor: Colors.white,
            shape: const CircleBorder(),
            onPressed: () {
              // Sensible default from Settings: jump to Chats
              context.push('/chats');
            },
            child: const Icon(Icons.chat_bubble_outline, size: 26),
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
                    _bottomItem(
                      icon: Icons.home_rounded,
                      label: 'Home',
                      onTap: () => context.go('/'),
                    ),
                    const SizedBox(width: 28),
                    _bottomItem(
                      icon: Icons.people_outline,
                      label: 'Network',
                      onTap: () => context.go('/'), // hook a tab if needed
                    ),
                  ],
                ),
              ),
              const SizedBox(width: kFabGapWidth),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Row(
                  children: [
                    _bottomItem(
                      icon: Icons.chat_bubble_outline,
                      label: 'Messages',
                      onTap: () => context.push('/chats'),
                    ),
                    const SizedBox(width: 28),
                    _bottomItem(
                      icon: Icons.settings_outlined,
                      label: 'Settings',
                      onTap: () {}, // already here
                      selected: true,
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
}
