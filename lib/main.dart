import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'theme.dart';
import 'app_router.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // TODO: replace with your Supabase keys
  await Supabase.initialize(
    url: 'https://rbgyqzpdcztnndicsfyb.supabase.co',
    anonKey: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJiZ3lxenBkY3p0bm5kaWNzZnliIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQ3MzkzODYsImV4cCI6MjA3MDMxNTM4Nn0.YFURLSgxZl98vmzDStg7xVA8F9KfOUOXKrLa6bTTDkc',
    authOptions: const FlutterAuthClientOptions(
      authFlowType: AuthFlowType.pkce,
      // persist session is on by default (remember me)
    ),
  );

  runApp(const BackStageApp());
}

class BackStageApp extends StatelessWidget {
  const BackStageApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'BackStage',
      debugShowCheckedModeBanner: false,
      theme: appTheme,
      routerConfig: router,
    );
  }
}
