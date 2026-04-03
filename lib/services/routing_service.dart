// lib/services/routing_service.dart
//
// Free OSRM routing — no API key required.
// PRODUCTION: The public demo server is rate-limited and for dev only.
// For production, self-host OSRM or swap the URL for a paid provider
// (Mapbox, HERE, etc.) — RouteResult and all callers stay unchanged.

import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

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
  static const _host = 'router.project-osrm.org';

  Future<RouteResult?> fetchRoute({
    required LatLng origin,
    required LatLng destination,
    VehicleProfile profile = VehicleProfile.driving,
  }) async {
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

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      if ((data['code'] as String?) != 'Ok') return null;

      final routes = data['routes'] as List<dynamic>;
      if (routes.isEmpty) return null;

      final route    = routes[0] as Map<String, dynamic>;
      final duration = (route['duration'] as num).toDouble();
      final distance = (route['distance'] as num).toDouble();
      final geometry = route['geometry'] as Map<String, dynamic>;
      final rawCoords = geometry['coordinates'] as List<dynamic>;

      final points = rawCoords.map((c) {
        final pair = c as List<dynamic>;
        return LatLng(
          (pair[1] as num).toDouble(),
          (pair[0] as num).toDouble(),
        );
      }).toList();

      return RouteResult(
        points:          points,
        durationSeconds: duration.round(),
        distanceMetres:  distance,
      );
    } catch (e) {
      debugPrint('RoutingService: failed — $e');
      return null;
    }
  }
}

final routingServiceProvider =
    Provider<RoutingService>((_) => RoutingService());
