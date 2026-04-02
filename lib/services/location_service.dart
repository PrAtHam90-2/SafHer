// lib/services/location_service.dart
//
// BUG FIX: The original positionStream was declared as async* which means
// every call to .positionStream created a brand-new Geolocator subscription.
// Since both TripNotifier._startMonitoring() and TripScreen._positionSub
// each called locationService.positionStream.listen(), there were always
// TWO simultaneous GPS subscriptions draining battery and requesting
// permissions twice.
//
// FIX: Convert to a lazily-initialised broadcast stream backed by a single
// StreamController. All listeners share one underlying Geolocator stream.
// The stream is torn down and recreated if the LocationService is ever
// disposed (which doesn't happen in production, but keeps the class clean).

import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

// ---------------------------------------------------------------------------
// Mock destination coordinates – Senapati Bapat Rd, Pune
// These are only used as the DEFAULT destination in TripState.
// Users can override them via TripNotifier.setDestination(lat, lng).
// ---------------------------------------------------------------------------
const double kDestinationLat = 18.5167;
const double kDestinationLng = 73.8450;

// ---------------------------------------------------------------------------
// LocationService
// ---------------------------------------------------------------------------
class LocationService {
  StreamController<Position>? _controller;
  StreamSubscription<Position>? _geoSub;

  /// Single shared broadcast stream of [Position] updates.
  ///
  /// All callers (TripNotifier, TripScreen, etc.) share one underlying
  /// Geolocator subscription — no duplicate GPS drains.
  ///
  /// The stream is initialised lazily on first access. Subsequent calls
  /// return the same stream instance.
  Stream<Position> get positionStream {
    if (_controller == null || _controller!.isClosed) {
      _controller = StreamController<Position>.broadcast(
        onListen: _startGeoLocator,
        onCancel: _stopGeoLocator,
      );
    }
    return _controller!.stream;
  }

  Future<void> _startGeoLocator() async {
    // 1 ── Ensure location service is on ────────────────────────────────────
    final serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _controller?.addError(const LocationServiceDisabledException());
      return;
    }

    // 2 ── Permission gate ──────────────────────────────────────────────────
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      _controller?.addError(
          const PermissionDeniedException('Location permission denied'));
      return;
    }

    // 3 ── High-accuracy continuous updates ─────────────────────────────────
    const LocationSettings settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // emit on every ≥5 m of movement
    );

    _geoSub = Geolocator.getPositionStream(locationSettings: settings).listen(
      (pos) => _controller?.add(pos),
      onError: (e) => _controller?.addError(e),
      cancelOnError: false,
    );
  }

  void _stopGeoLocator() {
    _geoSub?.cancel();
    _geoSub = null;
  }

  /// Call this when the service itself should be cleaned up (e.g., in tests).
  void dispose() {
    _geoSub?.cancel();
    _controller?.close();
    _controller = null;
  }

  // ---------------------------------------------------------------------------
  // remainingDistanceStream
  // NOTE: This stream uses the hardcoded kDestinationLat/Lng constants.
  // If you need it to reflect a dynamic destination set via
  // TripNotifier.setDestination(), compute the distance inside TripScreen
  // directly from tripProvider.state instead of using this stream.
  // ---------------------------------------------------------------------------
  Stream<double> get remainingDistanceStream async* {
    await for (final position in positionStream) {
      final metres = Geolocator.distanceBetween(
        position.latitude,
        position.longitude,
        kDestinationLat,
        kDestinationLng,
      );
      yield metres / 1000.0;
    }
  }
}

// ---------------------------------------------------------------------------
// Riverpod providers
// ---------------------------------------------------------------------------

/// Singleton [LocationService] — shared across the whole app.
final locationServiceProvider = Provider<LocationService>((ref) {
  final service = LocationService();
  ref.onDispose(service.dispose);
  return service;
});

/// Live [Position] stream — shared broadcast stream from the singleton service.
final positionStreamProvider = StreamProvider.autoDispose<Position>((ref) {
  return ref.watch(locationServiceProvider).positionStream;
});

/// Remaining km to destination using hardcoded destination constants.
/// See note in remainingDistanceStream above for dynamic destination support.
final distanceStreamProvider = StreamProvider.autoDispose<double>((ref) {
  return ref.watch(locationServiceProvider).remainingDistanceStream;
});
