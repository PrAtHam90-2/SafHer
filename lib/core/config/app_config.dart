// lib/core/config/app_config.dart
//
// Build-time configuration via --dart-define.
//
// Usage:
//   flutter run  --dart-define=OSRM_HOST=your-osrm-server.com
//   flutter build apk --dart-define=OSRM_HOST=your-osrm-server.com
//
// All values fall back to safe defaults so the app works out-of-the-box
// without any --dart-define flags.
//
// NEVER hardcode secret API keys here. Add them only as dart-define constants
// (they are compiled in but not stored in version control config files).

class AppConfig {
  AppConfig._(); // static-only class

  // ── Routing ───────────────────────────────────────────────────────────────

  /// OSRM routing server host.
  ///
  /// The public demo server is fine for development and low-volume use.
  /// For production, self-host OSRM and override with --dart-define:
  ///   --dart-define=OSRM_HOST=your-osrm-server.com
  static const osrmHost = String.fromEnvironment(
    'OSRM_HOST',
    defaultValue: 'router.project-osrm.org',
  );

  // ── Rate limiting ─────────────────────────────────────────────────────────

  /// Minimum gap between successive OSRM route requests (client-side guard).
  /// Prevents the app from hammering the routing server when the user
  /// rapidly changes source/destination or GPS ticks rapidly.
  static const routeRequestCooldown = Duration(seconds: 2);
}
