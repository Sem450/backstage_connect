import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../widgets/auth_text_field.dart';
import '../services/auth_service.dart';

class SignUpPage extends StatefulWidget {
  const SignUpPage({super.key});

  @override
  State<SignUpPage> createState() => _SignUpPageState();
}

class _SignUpPageState extends State<SignUpPage> {
  final emailC = TextEditingController();
  final passC = TextEditingController();
  final confirmC = TextEditingController();

  final _auth = AuthService();
  bool loading = false;
  String? error;
  bool remember = true;

  static const double kLogoTop = 90;
  static const double kLogoCardGap = 80;

  Future<void> _signup() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      if (passC.text != confirmC.text) {
        throw Exception('Passwords do not match.');
      }

      await _auth.signUp(
        email: emailC.text.trim(),
        password: passC.text,
        // role/displayName omitted; DB fills 'pending'
      );

      if (!mounted) return;
      context.go('/profile-setup');
    } catch (e) {
      setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  void dispose() {
    emailC.dispose();
    passC.dispose();
    confirmC.dispose();
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
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0x552A1D49), Color(0x88171026)],
              ),
            ),
          ),

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
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Create an Account',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Enter your email and password to continue',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.8),
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 18),

                        AuthTextField(
                          controller: emailC,
                          hint: 'Email address',
                          icon: Icons.alternate_email,
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 12),
                        AuthTextField(
                          controller: passC,
                          hint: 'Enter your password',
                          icon: Icons.lock_outline,
                          isPassword: true,
                        ),
                        const SizedBox(height: 12),
                        AuthTextField(
                          controller: confirmC,
                          hint: 'Confirm your password',
                          icon: Icons.lock_outline,
                          isPassword: true,
                        ),
                        const SizedBox(height: 10),

                        

                        if (error != null) ...[
                          Text(
                            error!,
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
                            onPressed: loading ? null : _signup,
                            child: loading
                                ? const CircularProgressIndicator(
                                    color: Colors.white,
                                  )
                                : const Text(
                                    'Continue',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 10),

                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Already have an account? ',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.85),
                              ),
                            ),
                            GestureDetector(
                              onTap: () => context.go('/login'),
                              child: const Text(
                                'Login',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
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
