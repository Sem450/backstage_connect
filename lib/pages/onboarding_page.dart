import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/auth_service.dart';
import '../models/app_user.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({super.key});

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  final _auth = AuthService();
  final _nameC = TextEditingController();

  bool _loading = true;
  String? _error;
  AppUser? _me;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final me = await _auth.currentProfile();
      _me = me;
      _nameC.text = (me?.displayName ?? '').trim();
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final name = _nameC.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Please enter a display name.');
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await _auth.updateDisplayName(name);
      // route to correct dashboard based on role
      final me = await _auth.currentProfile();
      if (!mounted || me == null) return;
      if (me.role == 'artist') {
        context.go('/artist');
      } else {
        context.go('/manager');
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF2A1D49), Color(0xFF171026)],
          ),
        ),
        child: Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                width: 360,
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 24,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: Colors.white.withOpacity(0.12)),
                ),
                child: _loading
                    ? const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
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
                            'Choose a public name people will see in chats and lists.',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.8),
                            ),
                          ),
                          const SizedBox(height: 16),
                          TextField(
                            controller: _nameC,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              hintText: 'Display name (e.g., Archie)',
                              hintStyle: const TextStyle(color: Colors.white70),
                              filled: true,
                              fillColor: const Color(0xFF2A1D49),
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
                          const SizedBox(height: 10),
                          if (_error != null) ...[
                            Text(
                              _error!,
                              style: const TextStyle(color: Colors.redAccent),
                            ),
                            const SizedBox(height: 6),
                          ],
                          SizedBox(
                            width: double.infinity,
                            height: 48,
                            child: ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                shape: const StadiumBorder(),
                                backgroundColor: const Color(0xFF8B5CF6),
                              ),
                              onPressed: _save,
                              child: const Text(
                                'Continue',
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
    );
  }
}
