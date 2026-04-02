import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/login_screen.dart';
import 'services/auth_provider.dart';

class SafHerApp extends ConsumerWidget {
  const SafHerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      // ── Still determining auth state (Firebase cold start) ────────────────
      loading: () => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const Scaffold(
          body: Center(
            child: CircularProgressIndicator(),
          ),
        ),
      ),

      // ── Auth stream error ─────────────────────────────────────────────────
      error: (_, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        home: const LoginScreen(),
      ),

      // ── Data: user logged in → app, null → login ──────────────────────────
      data: (user) => user == null
          ? MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightTheme,
              home: const LoginScreen(),
            )
          : MaterialApp.router(
              title: 'SafHer',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.lightTheme,
              routerConfig: appRouter,
            ),
    );
  }
}
