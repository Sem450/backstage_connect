import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'pages/splash_gate.dart';
import 'pages/login_page.dart';
import 'pages/signup_page.dart';
import 'pages/reset_password_page';
import 'pages/profile_setup_page.dart';
import 'pages/artist_dashboard.dart';
import 'pages/manager_dashboard.dart';
import 'pages/onboarding_page.dart';
import 'pages/settings_page.dart';
import 'pages/saved_analyses_page.dart';
import 'pages/avatar_setup_page.dart'; // remove if unused
import 'screens/chat_list_screen.dart';
import 'screens/chat_thread_screen.dart';

final router = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const SplashGate()),
    GoRoute(path: '/login', builder: (context, state) => const LoginPage()),
    GoRoute(path: '/signup', builder: (context, state) => const SignUpPage()),
    GoRoute(
      path: '/profile-setup',
      builder: (context, state) => const ProfileSetupPage(),
    ),
    GoRoute(
      path: '/artist',
      builder: (context, state) => const ArtistDashboard(),
    ),
    GoRoute(
      path: '/manager',
      builder: (context, state) => const ManagerDashboard(),
    ),
    GoRoute(
      path: '/onboarding',
      builder: (context, state) => const OnboardingPage(),
    ),
    GoRoute(
      path: '/avatar',
      builder: (context, state) => const AvatarSetupPage(),
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsPage(),
    ),
    GoRoute(
      path: '/saved-analyses',
      builder: (context, state) {
        final list = (state.extra as List<Map<String, dynamic>>?) ?? const [];
        return SavedAnalysesPage(analyses: list);
      },
    ),
    GoRoute(
      path: '/chats',
      builder: (context, state) {
        final extra = state.extra;
        final managedFromRoute = (extra is List)
            ? extra
                  .where((e) => e is Map)
                  .map((e) => (e as Map).cast<String, dynamic>())
                  .toList()
            : const <Map<String, dynamic>>[];
        return ChatListScreen(managedFromRoute: managedFromRoute);
      },
    ),
    GoRoute(
      path: '/chats/:chatId',
      builder: (context, state) {
        final extra = (state.extra is Map)
            ? (state.extra as Map).cast<String, dynamic>()
            : const <String, dynamic>{};
        return ChatThreadScreen(
          chatId: state.pathParameters['chatId']!,
          initialTitle: extra['initialTitle'] as String?,
          initialAvatarUrl: extra['initialAvatarUrl'] as String?,
        );
      },
    ),
    GoRoute(
      path: '/reset-callback',
      builder: (_, __) => const ResetPasswordPage(),
    ),
  ],
  errorBuilder: (context, state) =>
      const Material(child: Center(child: Text('Route not found'))),
);
