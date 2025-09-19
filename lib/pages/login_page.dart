import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../widgets/auth_text_field.dart';
import '../services/auth_service.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final emailC = TextEditingController();
  final passC = TextEditingController();
  bool remember = true;

  final _auth = AuthService();
  bool loading = false;
  String? error;

  bool get _emailLooksValid {
    final v = emailC.text.trim();
    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
    return re.hasMatch(v);
  }

  bool get _passwordLooksValid => passC.text.isNotEmpty;

  String _friendlyError(Object e) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('invalid login') || msg.contains('invalid credentials')) {
      return 'Incorrect email or password. Please try again.';
    }
    if (msg.contains('email') && msg.contains('confirm')) {
      return 'Please confirm your email before logging in. Check your inbox.';
    }
    if (msg.contains('rate') && msg.contains('limit') ||
        msg.contains('too many') || msg.contains('attempts')) {
      return 'Too many attempts—please wait a moment and try again.';
    }
    if (msg.contains('network') || msg.contains('timeout') ||
        msg.contains('host lookup')) {
      return 'Network issue—check your connection and try again.';
    }
    if (msg.contains('user') && msg.contains('not') && msg.contains('found')) {
      return 'We couldn’t find an account with that email.';
    }
    return 'Something went wrong. Please try again.';
  }

  Future<void> _attemptLogin() async {
    FocusScope.of(context).unfocus();
    if (!_emailLooksValid) {
      setState(() => error = 'Please enter a valid email address.');
      return;
    }
    if (!_passwordLooksValid) {
      setState(() => error = 'Please enter your password.');
      return;
    }
    await _login();
  }

  Future<void> _login() async {
    setState(() { loading = true; error = null; });
    try {
      final profile = await _auth.login(
        email: emailC.text.trim(),
        password: passC.text,
      );
      if (!mounted) return;

      if ((profile.displayName ?? '').trim().isEmpty) {
        context.go('/onboarding');
        return;
      }
      if (profile.role == 'artist') {
        context.go('/artist');
      } else {
        context.go('/manager');
      }
    } catch (e) {
      setState(() => error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // === Reset password flow ===
  Future<void> _openResetSheet() async {
    final c = TextEditingController(text: emailC.text.trim());
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final kb = MediaQuery.of(ctx).viewInsets.bottom;
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, kb + 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38, height: 4,
                  decoration: BoxDecoration(
                    color: Colors.black12,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Reset password',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              const SizedBox(height: 10),
              TextField(
                controller: c,
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(
                  labelText: 'Email address',
                  filled: true,
                  fillColor: const Color(0xFFF5F6FA),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.mail_outline),
                  label: const Text('Send reset link'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    final email = c.text.trim();
                    final re = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
                    if (!re.hasMatch(email)) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Enter a valid email.')),
                      );
                      return;
                    }
                    Navigator.pop(ctx); // close sheet
                    await _sendReset(email);
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _sendReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Reset link sent to $email'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_friendlyError(e)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  void dispose() {
    emailC.dispose();
    passC.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset("assets/bg.png", fit: BoxFit.cover),
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter, end: Alignment.bottomCenter,
                colors: [Color(0x552A1D49), Color(0x88171026)],
              ),
            ),
          ),

          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 90),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset('assets/logo_B.png', height: 47, filterQuality: FilterQuality.high),
                  const SizedBox(width: 17),
                  const Text('BackStage',
                    style: TextStyle(color: Colors.white, fontSize: 33, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),

          Center(
            child: Padding(
              padding: const EdgeInsets.only(top: 75),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    width: 340,
                    padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 24),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color.fromARGB(85, 38, 23, 74).withOpacity(0.3),
                          const Color.fromARGB(115, 67, 30, 127).withOpacity(0.3),
                        ],
                        begin: Alignment.topLeft, end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: Colors.white.withOpacity(0.12)),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Login',
                          style: TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 6),
                        Text('Welcome back please login to your account',
                          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 13),
                        ),
                        const SizedBox(height: 18),

                        AuthTextField(
                          controller: emailC,
                          hint: 'Email',
                          icon: Icons.person_outline,
                          keyboardType: TextInputType.emailAddress,
                        ),
                        if (error != null && !_emailLooksValid) ...[
                          const SizedBox(height: 6),
                          const Text('Enter a valid email address',
                              style: TextStyle(color: Color(0xFFFFB4AB))),
                        ],
                        const SizedBox(height: 12),

                        AuthTextField(
                          controller: passC,
                          hint: 'Password',
                          icon: Icons.lock_outline,
                          isPassword: true,
                        ),

                        // Forgot password link
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _openResetSheet,
                            child: const Text(
                              'Forgot password?',
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                        ),

                        if (error != null) ...[
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF5350).withOpacity(0.14),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: const Color(0xFFEF5350).withOpacity(0.35)),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(Icons.error_outline, color: Color(0xFFEF5350)),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(error!, style: const TextStyle(color: Color(0xFFEF5350), height: 1.35)),
                                ),
                                InkWell(
                                  onTap: () => setState(() => error = null),
                                  child: const Padding(
                                    padding: EdgeInsets.all(2),
                                    child: Icon(Icons.close, size: 18, color: Color(0xFFEF5350)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],

                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              shape: const StadiumBorder(),
                              backgroundColor: const Color(0xFF8B5CF6),
                            ),
                            onPressed: loading ? null : _attemptLogin,
                            child: loading
                                ? const CircularProgressIndicator(color: Colors.white)
                                : const Text('Login',
                                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text("Don't have an account? ",
                                style: TextStyle(color: Colors.white.withOpacity(0.85))),
                            GestureDetector(
                              onTap: () => context.go('/signup'),
                              child: const Text('Sign Up',
                                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                            ),
                          ],
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
