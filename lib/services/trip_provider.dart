import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'location_service.dart';
import 'trip_history_service.dart';

// ============================================================================
//  TripState  (unchanged)
// ============================================================================

class TripState {
  final bool isTripActive;
  /// True when the user has paused the trip mid-journey.
  final bool isPaused;
  final Position? currentPosition;
  final Position? startPosition;
  final double destinationLat;
  final double destinationLng;
  /// Human-readable label for the chosen destination (e.g. "FC Road, Pune").
  /// Empty string means no destination has been set yet.
  final String destinationLabel;

  const TripState({
    this.isTripActive = false,
    this.isPaused     = false,
    this.currentPosition,
    this.startPosition,
    this.destinationLat = 0.0,
    this.destinationLng = 0.0,
    this.destinationLabel = '',
  });

  /// True only when the user has actually picked a destination.
  bool get hasDestination => destinationLat != 0.0 || destinationLng != 0.0;

  TripState copyWith({
    bool? isTripActive,
    bool? isPaused,
    Position? currentPosition,
    Position? startPosition,
    double? destinationLat,
    double? destinationLng,
    String? destinationLabel,
  }) {
    return TripState(
      isTripActive:     isTripActive     ?? this.isTripActive,
      isPaused:         isPaused         ?? this.isPaused,
      currentPosition:  currentPosition  ?? this.currentPosition,
      startPosition:    startPosition    ?? this.startPosition,
      destinationLat:   destinationLat   ?? this.destinationLat,
      destinationLng:   destinationLng   ?? this.destinationLng,
      destinationLabel: destinationLabel ?? this.destinationLabel,
    );
  }

  double? get distanceToDestinationMetres {
    if (currentPosition == null || !hasDestination) return null;
    return Geolocator.distanceBetween(
      currentPosition!.latitude,
      currentPosition!.longitude,
      destinationLat,
      destinationLng,
    );
  }

  double? get deviationFromRouteMetres {
    if (currentPosition == null || startPosition == null) return null;

    const metersPerDegLat = 111320.0;
    final cosLat = cos(startPosition!.latitude * pi / 180);

    double toX(double lng) => (lng - startPosition!.longitude) * metersPerDegLat * cosLat;
    double toY(double lat) => (lat - startPosition!.latitude)  * metersPerDegLat;

    final bx = toX(destinationLng);
    final by = toY(destinationLat);
    final px = toX(currentPosition!.longitude);
    final py = toY(currentPosition!.latitude);

    final ab2 = bx * bx + by * by;
    if (ab2 == 0) return null;

    final cross = (bx * py - by * px).abs();
    return cross / sqrt(ab2);
  }
}

// ============================================================================
//  TripNotifier
// ============================================================================

class TripNotifier extends Notifier<TripState> {
  StreamSubscription<Position>? _positionSub;

  // ── GPS filtering ─────────────────────────────────────────────────────────
  /// Last position that passed the jitter filter. Updated only when the device
  /// moves at least [_jitterFilterM] metres from the previous accepted point.
  Position? _lastAcceptedPosition;

  /// Counts consecutive GPS updates that meet the auto check-in criteria.
  /// A trip starts only after [_requiredConsecutiveUpdates] qualifying updates
  /// in a row, preventing single noisy readings from triggering a false start.
  int _consecutiveGoodUpdates = 0;

  // ── Anomaly detection state ───────────────────────────────────────────────
  DateTime? _lowSpeedSince;
  bool _stopAlertFired  = false;
  bool _deviationFired  = false;

  // ── Trip history tracking ─────────────────────────────────────────────────
  DateTime? _tripStartTime;
  bool _hadAnomaly = false;

  // ── Thresholds ────────────────────────────────────────────────────────────
  /// Minimum speed (km/h) required for auto check-in via speed reading.
  static const double _speedCheckInKmh        = 5.0;

  /// Minimum movement (m) between two *accepted* positions to qualify for
  /// auto check-in via distance. Deliberately higher than [_jitterFilterM]
  /// so that slow drift does not trigger a false start.
  static const double _checkInMovementM        = 20.0;

  /// Minimum movement (m) to accept a GPS update as real movement.
  /// Updates smaller than this are discarded as GPS jitter.
  static const double _jitterFilterM           = 10.0;

  /// How many consecutive qualifying updates are required before a trip
  /// auto-starts. Prevents a single noisy GPS spike from starting a trip.
  static const int    _requiredConsecutiveUpdates = 2;

  static const double _checkOutRadiusM         = 100.0;
  static const double _stopSpeedKmh            = 2.0;
  static const int    _stopSeconds             = 30;
  static const double _deviationThresholdM     = 500.0;

  // ── Anomaly stream ────────────────────────────────────────────────────────
  final _anomalyController = StreamController<String>.broadcast();
  Stream<String> get anomalyStream => _anomalyController.stream;

  @override
  TripState build() {
    final locationService = ref.watch(locationServiceProvider);
    _startMonitoring(locationService);
    ref.onDispose(() {
      _positionSub?.cancel();
      _anomalyController.close();
    });
    return const TripState();
  }

  // ── Internal ──────────────────────────────────────────────────────────────

  void _startMonitoring(LocationService locationService) {
    _positionSub?.cancel();
    _positionSub = locationService.positionStream.listen(
      _onPosition,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _onPosition(Position position) {
    // ── Jitter filter ────────────────────────────────────────────────────────
    // Discard GPS updates that are smaller than [_jitterFilterM] from the last
    // accepted position. This eliminates sub-10m noise from stationary devices.
    if (_lastAcceptedPosition != null) {
      final jitter = Geolocator.distanceBetween(
        _lastAcceptedPosition!.latitude,  _lastAcceptedPosition!.longitude,
        position.latitude,                position.longitude,
      );
      if (jitter < _jitterFilterM) {
        // Position is within jitter range — update state for UI but skip logic.
        state = state.copyWith(currentPosition: position);
        return;
      }
    }
    // This update passed the filter — record it as the new accepted baseline.
    _lastAcceptedPosition = position;
    state = state.copyWith(currentPosition: position);

    // ── Auto check-in ────────────────────────────────────────────────────────
    if (!state.isTripActive) {
      if (_shouldAutoCheckIn(position)) {
        _tripStartTime = DateTime.now();
        _hadAnomaly    = false;
        _consecutiveGoodUpdates = 0;          // reset after successful start
        state = state.copyWith(
          isTripActive:  true,
          isPaused:      false,
          startPosition: position,
        );
        debugPrint('Trip started automatically');
      }
      return; // nothing else to do until trip is active
    }

    // ── Paused guard ─────────────────────────────────────────────────────────
    // While paused, keep updating position for UI but skip auto-checkout and
    // anomaly detection so the user isn't alerted while intentionally stopped.
    if (state.isPaused) return;

    // ── Auto check-out — only when a destination has been set ────────────────
    if (state.hasDestination) {
      final dist = state.distanceToDestinationMetres;
      if (dist != null && dist < _checkOutRadiusM) {
        _saveTripToHistory();
        state = state.copyWith(isTripActive: false, isPaused: false);
        debugPrint('Trip ended automatically — destination reached');
        _lastAcceptedPosition = null;
        _consecutiveGoodUpdates = 0;
        _resetAnomalyState();
        return;
      }
    }

    // ── Anomaly detection ─────────────────────────────────────────────────────
    _detectSuddenStop(position);
    if (state.hasDestination) _detectRouteDeviation();
  }

  /// Returns true once [_requiredConsecutiveUpdates] qualifying GPS readings
  /// have been received in a row. A qualifying reading is one where either:
  ///   • the reported speed exceeds [_speedCheckInKmh], OR
  ///   • the device moved at least [_checkInMovementM] from the last accepted
  ///     position (already guaranteed > [_jitterFilterM] by the filter above).
  bool _shouldAutoCheckIn(Position position) {
    final speedKmh = position.speed >= 0 ? position.speed * 3.6 : 0.0;

    bool qualifies = false;

    // Criterion 1: speed sensor says we are moving
    if (speedKmh >= _speedCheckInKmh) {
      qualifies = true;
    }

    // Criterion 2: significant distance moved from last accepted position
    if (!qualifies && _lastAcceptedPosition != null) {
      final moved = Geolocator.distanceBetween(
        _lastAcceptedPosition!.latitude,  _lastAcceptedPosition!.longitude,
        position.latitude,                position.longitude,
      );
      if (moved >= _checkInMovementM) qualifies = true;
    }

    if (qualifies) {
      _consecutiveGoodUpdates++;
      debugPrint(
        'Auto check-in progress: '
        '$_consecutiveGoodUpdates/$_requiredConsecutiveUpdates '
        '(speed=${speedKmh.toStringAsFixed(1)} km/h)',
      );
      return _consecutiveGoodUpdates >= _requiredConsecutiveUpdates;
    } else {
      // Reset counter — movement must be *sustained*, not sporadic
      _consecutiveGoodUpdates = 0;
      return false;
    }
  }

  void _detectSuddenStop(Position position) {
    final speedKmh = position.speed >= 0 ? position.speed * 3.6 : 0.0;
    if (speedKmh < _stopSpeedKmh) {
      _lowSpeedSince ??= DateTime.now();
      final elapsed = DateTime.now().difference(_lowSpeedSince!).inSeconds;
      if (elapsed >= _stopSeconds && !_stopAlertFired) {
        _stopAlertFired = true;
        _hadAnomaly     = true; // NEW
        _anomalyController.add('⚠️ Route anomaly detected: Unexpected stop');
      }
    } else {
      _lowSpeedSince  = null;
      _stopAlertFired = false;
    }
  }

  void _detectRouteDeviation() {
    final deviation = state.deviationFromRouteMetres;
    if (deviation != null && deviation > _deviationThresholdM && !_deviationFired) {
      _deviationFired = true;
      _hadAnomaly     = true; // NEW
      _anomalyController.add('⚠️ Route anomaly detected: Unusual route taken');
    } else if (deviation != null && deviation <= _deviationThresholdM) {
      _deviationFired = false;
    }
  }

  void _resetAnomalyState() {
    _lowSpeedSince  = null;
    _stopAlertFired = false;
    _deviationFired = false;
  }

  void _resetCheckInState() {
    _consecutiveGoodUpdates = 0;
    _lastAcceptedPosition   = null;
  }

  // ── NEW: persist completed trip to Firestore ──────────────────────────────

  void _saveTripToHistory() {
    // Guard: need both a start time and positions
    if (_tripStartTime == null) return;
    if (state.startPosition == null || state.currentPosition == null) return;

    final record = TripRecord(
      id:          '',
      startedAt:   _tripStartTime!,
      endedAt:     DateTime.now(),
      startLat:    state.startPosition!.latitude,
      startLng:    state.startPosition!.longitude,
      endLat:      state.currentPosition!.latitude,
      endLng:      state.currentPosition!.longitude,
      distanceTravelledKm: Geolocator.distanceBetween(
        state.startPosition!.latitude,
        state.startPosition!.longitude,
        state.currentPosition!.latitude,
        state.currentPosition!.longitude,
      ) / 1000.0,
      hadAnomaly: _hadAnomaly,
    );

    // Fire-and-forget: history save must never crash the trip logic
    ref.read(tripHistoryServiceProvider).saveTrip(record).then((_) {
      // Refresh HomeScreen trip list after a successful save
      ref.invalidate(tripHistoryProvider);
    }).catchError((e) {
      debugPrint('TripNotifier: failed to save trip history — $e');
    });

    // Reset for the next trip
    _tripStartTime = null;
    _hadAnomaly    = false;
  }

  // ── Public API ────────────────────────────────────────────────────────────

  void startTripManually() {
    _tripStartTime = DateTime.now();
    _hadAnomaly    = false;
    _resetAnomalyState();
    _resetCheckInState();
    state = state.copyWith(
      isTripActive:  true,
      isPaused:      false,
      startPosition: state.currentPosition,
    );
  }

  /// End the active trip immediately and save it to history.
  void endTripManually() {
    _saveTripToHistory();
    state = state.copyWith(isTripActive: false, isPaused: false);
    _resetAnomalyState();
    _resetCheckInState();
  }

  /// Pause the trip mid-journey.
  /// Anomaly detection and auto-checkout are suspended while paused.
  /// Call again (or [resumeTrip]) to resume.
  void pauseTripManually() {
    if (!state.isTripActive) return;
    state = state.copyWith(isPaused: true);
    // Reset the stop-timer so a deliberate stop does not fire a false alert
    _lowSpeedSince  = null;
    _stopAlertFired = false;
    debugPrint('Trip paused manually');
  }

  /// Resume a previously paused trip.
  void resumeTrip() {
    if (!state.isTripActive) return;
    state = state.copyWith(isPaused: false);
    debugPrint('Trip resumed');
  }

  void setDestination(double lat, double lng, {String label = ''}) {
    state = state.copyWith(
      destinationLat:   lat,
      destinationLng:   lng,
      destinationLabel: label,
    );
    // Reset deviation flag so a fresh check runs with the new destination
    _deviationFired = false;
  }
}

// ============================================================================
//  Provider  (unchanged)
// ============================================================================

final tripProvider = NotifierProvider<TripNotifier, TripState>(
  TripNotifier.new,
);
