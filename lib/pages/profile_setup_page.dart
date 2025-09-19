// lib/pages/profile_setup_page.dart
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:file_picker/file_picker.dart';

import '../services/auth_service.dart';

class ProfileSetupPage extends StatefulWidget {
  const ProfileSetupPage({super.key});

  @override
  State<ProfileSetupPage> createState() => _ProfileSetupPageState();
}

class _ProfileSetupPageState extends State<ProfileSetupPage> {
  final _auth = AuthService();

  final nameC = TextEditingController();
  String? role; // 'artist' or 'manager'
  Uint8List? avatarBytes; // picked bytes
  String _avatarExt = 'jpg'; // used when uploading (png/jpg)

  bool loading = false;
  String? error;

  static const double kLogoTop = 90;
  static const double kLogoCardGap = 80;

  @override
  void dispose() {
    nameC.dispose();
    super.dispose();
  }

  Future<void> _pickAvatar() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true, // <-- always get bytes (works on web + mobile)
      );
      if (res == null) return;

      final file = res.files.single;
      final bytes = file.bytes; // <-- use bytes, not path
      if (bytes == null) {
        throw Exception('Could not read image bytes.');
      }

      // detect extension (default to jpg)
      final ext = (file.extension ?? '').toLowerCase();
      _avatarExt = ext == 'png' ? 'png' : 'jpg';

      setState(() {
        avatarBytes = bytes;
        error = null;
      });
    } catch (e) {
      setState(() => error = 'Image error: $e');
    }
  }

  Future<void> _finish() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final displayName = nameC.text.trim();
      if (displayName.isEmpty) {
        throw Exception('Please enter a display name.');
      }
      if (role == null) {
        throw Exception('Please choose a role.');
      }

      await _auth.updateDisplayName(displayName);
      await _auth.updateRole(role: role!);
      if (avatarBytes != null) {
        await _auth.updateAvatarFromBytes(avatarBytes!, ext: _avatarExt);
      }

      if (!mounted) return;
      context.go(role == 'artist' ? '/artist' : '/manager');
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background
          Image.asset('assets/bg.png', fit: BoxFit.cover),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x552A1D49), Color(0x88171026)],
              ),
            ),
          ),

          // Logo row
          Align(
            alignment: Alignment.topCenter,
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.only(top: kLogoTop),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Image.asset(
                      'assets/logo_B.png',
                      height: 56,
                      filterQuality: FilterQuality.high,
                    ),
                    const SizedBox(width: 12),
                    const Text(
                      'BackStage',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Card
          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: kLogoCardGap),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    width: 340,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 22,
                      vertical: 24,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color.fromARGB(85, 38, 23, 74).withOpacity(0.3),
                          const Color.fromARGB(
                            115,
                            67,
                            30,
                            127,
                          ).withOpacity(0.3),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.white.withOpacity(0.12)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Set up your profile',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Add your display name, choose a role, and set a profile picture',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Avatar picker
                        Center(
                          child: Column(
                            children: [
                              CircleAvatar(
                                radius: 40,
                                backgroundColor: const Color(0x338B5CF6),
                                backgroundImage: avatarBytes != null
                                    ? MemoryImage(avatarBytes!)
                                    : null,
                                child: avatarBytes == null
                                    ? const Icon(
                                        Icons.person,
                                        color: Colors.white70,
                                        size: 42,
                                      )
                                    : null,
                              ),
                              const SizedBox(height: 10),
                              TextButton.icon(
                                onPressed: _pickAvatar,
                                icon: const Icon(
                                  Icons.photo_camera,
                                  color: Colors.white,
                                ),
                                label: const Text(
                                  'Choose picture',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                style: TextButton.styleFrom(
                                  foregroundColor: Colors.white,
                                  overlayColor: const Color(0x338B5CF6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Display name
                        TextField(
                          controller: nameC,
                          style: const TextStyle(color: Colors.white),
                          decoration: InputDecoration(
                            hintText: 'Display name',
                            hintStyle: const TextStyle(color: Colors.white70),
                            filled: true,
                            fillColor: Colors.white.withOpacity(0.06),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12),
                              borderSide: BorderSide.none,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 12,
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),

                        // Role dropdown
                        Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: Colors.white.withOpacity(0.18),
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: role,
                              dropdownColor: const Color(0xFF2A1D49),
                              hint: Text(
                                'Choose role',
                                style: TextStyle(
                                  color: Colors.white.withOpacity(0.7),
                                ),
                              ),
                              items: const [
                                DropdownMenuItem(
                                  value: 'artist',
                                  child: Text('Artist'),
                                ),
                                DropdownMenuItem(
                                  value: 'manager',
                                  child: Text('Manager'),
                                ),
                              ],
                              onChanged: (v) => setState(() => role = v),
                              style: const TextStyle(color: Colors.white),
                              iconEnabledColor: Colors.white,
                            ),
                          ),
                        ),

                        if (error != null) ...[
                          const SizedBox(height: 10),
                          Text(
                            error!,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ],
                        const SizedBox(height: 16),

                        SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              shape: const StadiumBorder(),
                              backgroundColor: const Color(0xFF8B5CF6),
                            ),
                            onPressed: loading ? null : _finish,
                            child: loading
                                ? const CircularProgressIndicator(
                                    color: Colors.white,
                                  )
                                : const Text(
                                    'Finish',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
