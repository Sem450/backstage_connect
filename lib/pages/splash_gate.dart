import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/auth_service.dart';

class SplashGate extends StatefulWidget {
  const SplashGate({super.key});

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  final _auth = AuthService();

  @override
  void initState() {
    super.initState();
    _route();
    // react to auth changes (e.g., logout)
    Supabase.instance.client.auth.onAuthStateChange.listen((event) {
      _route();
    });
  }

  Future<void> _route() async {
    final session = Supabase.instance.client.auth.currentSession;
    if (session == null) {
      if (mounted) context.go('/login');
      return;
    }
    final profile = await _auth.currentProfile();
    if (!mounted) return;
    if (profile == null) {
      context.go('/login');
    } else if (profile.role == 'artist') {
      context.go('/artist');
    } else {
      context.go('/manager');
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
