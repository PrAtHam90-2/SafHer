// lib/services/routing_service.dart
//
// Free OSRM routing — no API key required.
// PRODUCTION: The public demo server is rate-limited and for dev only.
// For production, self-host OSRM and set --dart-define=OSRM_HOST=<your-host>
// RouteResult and all callers remain unchanged.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../core/config/app_config.dart';

// ============================================================================
//  VehicleProfile — extensible routing mode
// ============================================================================

enum VehicleProfile {
  driving('driving'),
  cycling('cycling'),
  walking('walking');

  final String osrmProfile;
  const VehicleProfile(this.osrmProfile);
}

// ============================================================================
//  RouteResult
// ============================================================================

class RouteResult {
  final List<LatLng> points;
  final int durationSeconds;
  final double distanceMetres;

  const RouteResult({
    required this.points,
    required this.durationSeconds,
    required this.distanceMetres,
  });

  int get etaMinutes => (durationSeconds / 60).ceil();

  String get etaLabel {
    if (etaMinutes < 60) return '$etaMinutes min';
    final h = etaMinutes ~/ 60;
    final m = etaMinutes % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  double get distanceKm => distanceMetres / 1000.0;
}

// ============================================================================
//  RoutingService
// ============================================================================

class RoutingService {
  // OSRM host is read from --dart-define at build time; falls back to
  // the public demo server when no override is provided.
  static final String _host = AppConfig.osrmHost;

  // ── Client-side rate limiter ──────────────────────────────────────────────
  // Prevents hammering the routing server when the user rapidly changes
  // source/destination or the GPS position stream fires quickly.
  DateTime? _lastRequestAt;

  bool _isRateLimited() {
    final now = DateTime.now();
    if (_lastRequestAt != null &&
        now.difference(_lastRequestAt!) < AppConfig.routeRequestCooldown) {
      debugPrint('RoutingService: request throttled (cooldown active)');
      return true;
    }
    _lastRequestAt = now;
    return false;
  }

  // ── Coordinate validation ─────────────────────────────────────────────────
  // Rejects nonsense coordinates before they are sent to the API.
  bool _isValidCoordinate(LatLng ll) {
    return ll.latitude  >= -90  && ll.latitude  <= 90 &&
           ll.longitude >= -180 && ll.longitude <= 180;
  }

  // ── Main fetch ─────────────────────────────────────────────────────────────
  Future<RouteResult?> fetchRoute({
    required LatLng origin,
    required LatLng destination,
    VehicleProfile profile = VehicleProfile.driving,
  }) async {
    // 1. Validate coordinates — never send garbage to the API.
    if (!_isValidCoordinate(origin) || !_isValidCoordinate(destination)) {
      debugPrint('RoutingService: invalid coordinates — request blocked');
      return null;
    }

    // 2. Enforce rate limit — silently return null on cooldown.
    if (_isRateLimited()) return null;

    // 3. Build and fire the request.
    final coords =
        '${origin.longitude},${origin.latitude};'
        '${destination.longitude},${destination.latitude}';

    final uri = Uri.https(
      _host,
      '/route/v1/${profile.osrmProfile}/$coords',
      {'overview': 'full', 'geometries': 'geojson', 'steps': 'false'},
    );

    try {
      final response = await http
          .get(uri, headers: {'User-Agent': 'SafHer/1.0 (github.com/safher-app)'})
          .timeout(const Duration(seconds: 10));

      // 4. Safe HTTP error handling — log status code without echoing the URL
      //    (which contains user coordinates).
      if (response.statusCode != 200) {
        debugPrint('RoutingService: HTTP ${response.statusCode}');
        return null;
      }

      // 5. Safe JSON decoding with schema validation.
      final dynamic body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;

      if ((body['code'] as String?) != 'Ok') return null;

      final routes = body['routes'];
      if (routes is! List || routes.isEmpty) return null;

      final route = routes[0];
      if (route is! Map<String, dynamic>) return null;

      final duration = route['duration'];
      final distance = route['distance'];
      final geometry = route['geometry'];

      if (duration is! num || distance is! num) return null;
      if (geometry is! Map<String, dynamic>) return null;

      final rawCoords = geometry['coordinates'];
      if (rawCoords is! List) return null;

      final points = <LatLng>[];
      for (final c in rawCoords) {
        if (c is! List || c.length < 2) continue;
        final lng = c[0];
        final lat = c[1];
        if (lng is! num || lat is! num) continue;
        points.add(LatLng(lat.toDouble(), lng.toDouble()));
      }

      if (points.isEmpty) return null;

      return RouteResult(
        points:          points,
        durationSeconds: duration.round(),
        distanceMetres:  distance.toDouble(),
      );
    } on FormatException {
      debugPrint('RoutingService: invalid JSON response');
      return null;
    } catch (e) {
      // Catch network errors, timeouts, etc. Do not log 'e' directly as it
      // may contain the request URL (which embeds user coordinates).
      debugPrint('RoutingService: request failed');
      return null;
    }
  }
}

final routingServiceProvider =
    Provider<RoutingService>((_) => RoutingService());
