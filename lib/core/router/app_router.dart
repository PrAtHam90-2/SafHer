import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../features/home/home_screen.dart';
import '../../features/navigation/bottom_nav_screen.dart';
import '../../features/panic/panic_screen.dart';
import '../../features/trip/trip_screen.dart';
import '../../features/verify/verify_screen.dart';
import '../../features/contacts/contacts_screen.dart';

final rootNavigatorKey  = GlobalKey<NavigatorState>();
final shellNavigatorKey = GlobalKey<NavigatorState>();

final GoRouter appRouter = GoRouter(
  navigatorKey: rootNavigatorKey,
  initialLocation: '/home',
  routes: [
    ShellRoute(
      navigatorKey: shellNavigatorKey,
      builder: (context, state, child) {
        return BottomNavScreen(child: child);
      },
      routes: [
        GoRoute(
          path: '/home',
          builder: (context, state) => const HomeScreen(),
        ),
        GoRoute(
          path: '/trip',
          builder: (context, state) => const TripScreen(),
        ),
        GoRoute(
          path: '/verify',
          builder: (context, state) => const VerifyScreen(),
        ),
        GoRoute(
          path: '/sos',
          builder: (context, state) => const PanicScreen(),
        ),
        // ── PART 3: contacts route ──────────────────────────────────────
        GoRoute(
          path: '/contacts',
          builder: (context, state) => const ContactsScreen(),
        ),
      ],
    ),
  ],
);
