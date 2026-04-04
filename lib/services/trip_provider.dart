// lib/services/trip_provider.dart

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'location_service.dart';
import 'risk_engine.dart';          // ← NEW
import 'trip_history_service.dart';

// ============================================================================
//  TripState
// ============================================================================

class TripState {
  final bool isTripActive;
  final bool isPaused;
  final Position? currentPosition;
  final Position? startPosition;

  // Source
  final double sourceLat;
  final double sourceLng;
  final String sourceLabel;

  // Destination
  final double destinationLat;
  final double destinationLng;
  final String destinationLabel;

  // ── NEW: live risk snapshot ─────────────────────────────────────────────
  final RiskSnapshot risk;

  TripState({
    this.isTripActive     = false,
    this.isPaused         = false,
    this.currentPosition,
    this.startPosition,
    this.sourceLat        = 0.0,
    this.sourceLng        = 0.0,
    this.sourceLabel      = '',
    this.destinationLat   = 0.0,
    this.destinationLng   = 0.0,
    this.destinationLabel = '',
    // Default to idle snapshot — typed const is safe because RiskSnapshot.idle
    // creates a new DateTime each call, so we use the factory below instead.
    RiskSnapshot? risk,
  }) : risk = risk ?? _IdleRiskSnapshot();

  bool get hasSource      => sourceLat != 0.0 || sourceLng != 0.0;
  bool get hasDestination => destinationLat != 0.0 || destinationLng != 0.0;

  TripState copyWith({
    bool?          isTripActive,
    bool?          isPaused,
    Position?      currentPosition,
    Position?      startPosition,
    double?        sourceLat,
    double?        sourceLng,
    String?        sourceLabel,
    double?        destinationLat,
    double?        destinationLng,
    String?        destinationLabel,
    RiskSnapshot?  risk,            // ← NEW
  }) {
    return TripState(
      isTripActive:     isTripActive     ?? this.isTripActive,
      isPaused:         isPaused         ?? this.isPaused,
      currentPosition:  currentPosition  ?? this.currentPosition,
      startPosition:    startPosition    ?? this.startPosition,
      sourceLat:        sourceLat        ?? this.sourceLat,
      sourceLng:        sourceLng        ?? this.sourceLng,
      sourceLabel:      sourceLabel      ?? this.sourceLabel,
      destinationLat:   destinationLat   ?? this.destinationLat,
      destinationLng:   destinationLng   ?? this.destinationLng,
      destinationLabel: destinationLabel ?? this.destinationLabel,
      risk:             risk             ?? this.risk,
    );
  }

  double? get distanceToDestinationMetres {
    if (currentPosition == null || !hasDestination) return null;
    return Geolocator.distanceBetween(
      currentPosition!.latitude, currentPosition!.longitude,
      destinationLat,             destinationLng,
    );
  }

  double? get deviationFromRouteMetres {
    if (currentPosition == null || startPosition == null) return null;
    const metersPerDegLat = 111320.0;
    final cosLat = cos(startPosition!.latitude * pi / 180);
    double toX(double lng) =>
        (lng - startPosition!.longitude) * metersPerDegLat * cosLat;
    double toY(double lat) =>
        (lat - startPosition!.latitude) * metersPerDegLat;
    final bx  = toX(destinationLng);
    final by  = toY(destinationLat);
    final px  = toX(currentPosition!.longitude);
    final py  = toY(currentPosition!.latitude);
    final ab2 = bx * bx + by * by;
    if (ab2 == 0) return null;
    return (bx * py - by * px).abs() / sqrt(ab2);
  }
}

// Private const-safe idle snapshot used as the default field value.
// RiskSnapshot has a DateTime so it cannot be const directly; this sentinel
// subclass is const and gets replaced by the first real evaluation.
class _IdleRiskSnapshot extends RiskSnapshot {
  _IdleRiskSnapshot()
      : super(
          score:     0,
          level:     RiskLevel.safe,
          reason:    '',
          updatedAt: _epoch,
        );

  // Far-past sentinel — any real DateTime will be newer.
  static final _epoch = DateTime.utc(2000);
}

// ============================================================================
//  TripNotifier
// ============================================================================

class TripNotifier extends Notifier<TripState> {
  StreamSubscription<Position>? _positionSub;

  Position? _lastAcceptedPosition;
  int       _consecutiveGoodUpdates = 0;

  // Anomaly detection
  DateTime? _lowSpeedSince;
  bool      _stopAlertFired = false;
  bool      _deviationFired = false;

  // Trip history
  DateTime? _tripStartTime;
  bool      _hadAnomaly = false;

  // ── NEW: risk engine (stateless pure object) ────────────────────────────
  final _riskEngine = const RiskEngine();

  // ── NEW: last risk level — used to gate "High Risk" snackbar ───────────
  // We track this separately from state so we can compare old vs new level
  // without the overhead of reading state twice in _onPosition.
  RiskLevel _lastEmittedRiskLevel = RiskLevel.safe;

  // ── Thresholds ─────────────────────────────────────────────────────────
  static const double _speedCheckInKmh           = 5.0;
  static const double _checkInMovementM          = 20.0;
  static const double _jitterFilterM             = 10.0;
  static const int    _requiredConsecutiveUpdates = 2;
  static const double _checkOutRadiusM           = 80.0;
  static const double _stopSpeedKmh              = 2.0;
  static const int    _stopSeconds               = 30;
  static const double _deviationThresholdM       = 500.0;

  // ── Anomaly stream (consumed by TripScreen for Snackbars) ──────────────
  final _anomalyController = StreamController<String>.broadcast();
  Stream<String> get anomalyStream => _anomalyController.stream;

  // ── NEW: risk alert stream (separate from anomaly to avoid coupling) ────
  // Carries a RiskSnapshot whenever level escalates to High Risk or Critical.
  final _riskAlertController = StreamController<RiskSnapshot>.broadcast();
  Stream<RiskSnapshot> get riskAlertStream => _riskAlertController.stream;

  @override
  TripState build() {
    final locationService = ref.watch(locationServiceProvider);
    _startMonitoring(locationService);
    ref.onDispose(() {
      _positionSub?.cancel();
      _anomalyController.close();
      _riskAlertController.close();
    });
    return TripState();
  }

  void _startMonitoring(LocationService locationService) {
    _positionSub?.cancel();
    _positionSub = locationService.positionStream.listen(
      _onPosition,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _onPosition(Position position) {
    // ── Jitter filter ──────────────────────────────────────────────────────
    if (_lastAcceptedPosition != null) {
      final jitter = Geolocator.distanceBetween(
        _lastAcceptedPosition!.latitude, _lastAcceptedPosition!.longitude,
        position.latitude,              position.longitude,
      );
      if (jitter < _jitterFilterM) {
        state = state.copyWith(currentPosition: position);
        return;
      }
    }
    _lastAcceptedPosition = position;
    state = state.copyWith(currentPosition: position);

    // ── Auto check-in ──────────────────────────────────────────────────────
    if (!state.isTripActive) {
      if (_shouldAutoCheckIn(position)) {
        _tripStartTime = DateTime.now();
        _hadAnomaly    = false;
        _consecutiveGoodUpdates = 0;
        _lastEmittedRiskLevel   = RiskLevel.safe;
        state = state.copyWith(
          isTripActive:  true,
          isPaused:      false,
          startPosition: position,
          risk:          RiskSnapshot.idle,
        );
        debugPrint('Trip started automatically');
      }
      return;
    }

    if (state.isPaused) return;

    // ── Auto check-out ─────────────────────────────────────────────────────
    if (state.hasDestination) {
      final dist = state.distanceToDestinationMetres;
      if (dist != null && dist < _checkOutRadiusM) {
        _saveTripToHistory();
        state = state.copyWith(
          isTripActive: false,
          isPaused:     false,
          risk:         RiskSnapshot.idle,
        );
        debugPrint('Trip ended automatically');
        _lastAcceptedPosition = null;
        _consecutiveGoodUpdates = 0;
        _lastEmittedRiskLevel   = RiskLevel.safe;
        _resetAnomalyState();
        return;
      }
    }

    // ── Existing anomaly detection (unchanged) ─────────────────────────────
    _detectSuddenStop(position);
    if (state.hasDestination) _detectRouteDeviation();

    // ── NEW: risk evaluation ───────────────────────────────────────────────
    // Called only for accepted positions while trip is active and not paused.
    // The engine is pure — no side effects, no async work.
    _evaluateRisk(position);
  }

  // ── NEW: risk evaluation ─────────────────────────────────────────────────
  void _evaluateRisk(Position position) {
    final stopSecs = _lowSpeedSince != null
        ? DateTime.now().difference(_lowSpeedSince!).inSeconds
        : 0;

    final input = RiskInput(
      deviationMetres:    state.deviationFromRouteMetres,
      stopDurationSeconds: stopSecs,
      currentHour:        DateTime.now().hour,
    );

    final snapshot = _riskEngine.evaluate(input);

    // Update state with new snapshot
    state = state.copyWith(risk: snapshot);

    // Emit alert stream only when level escalates to High Risk / Critical
    // for the first time (prevents flooding on every GPS tick).
    if (snapshot.isHighAlert &&
        !_lastEmittedRiskLevel.isHighAlert) {
      _riskAlertController.add(snapshot);
    }
    _lastEmittedRiskLevel = snapshot.level;
  }

  // ── Auto check-in logic (unchanged) ─────────────────────────────────────

  bool _shouldAutoCheckIn(Position position) {
    final speedKmh = position.speed >= 0 ? position.speed * 3.6 : 0.0;
    bool qualifies = speedKmh >= _speedCheckInKmh;
    if (!qualifies && _lastAcceptedPosition != null) {
      final moved = Geolocator.distanceBetween(
        _lastAcceptedPosition!.latitude, _lastAcceptedPosition!.longitude,
        position.latitude,              position.longitude,
      );
      if (moved >= _checkInMovementM) qualifies = true;
    }
    if (qualifies) {
      _consecutiveGoodUpdates++;
      return _consecutiveGoodUpdates >= _requiredConsecutiveUpdates;
    } else {
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
        _hadAnomaly     = true;
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
      _hadAnomaly     = true;
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

  void _saveTripToHistory() {
    if (_tripStartTime == null) return;
    if (state.startPosition == null || state.currentPosition == null) return;
    final record = TripRecord(
      id:        '',
      startedAt: _tripStartTime!,
      endedAt:   DateTime.now(),
      startLat:  state.startPosition!.latitude,
      startLng:  state.startPosition!.longitude,
      endLat:    state.currentPosition!.latitude,
      endLng:    state.currentPosition!.longitude,
      distanceTravelledKm: Geolocator.distanceBetween(
        state.startPosition!.latitude, state.startPosition!.longitude,
        state.currentPosition!.latitude, state.currentPosition!.longitude,
      ) / 1000.0,
      hadAnomaly: _hadAnomaly,
    );
    ref.read(tripHistoryServiceProvider).saveTrip(record).then((_) {
      ref.invalidate(tripHistoryProvider);
    }).catchError((e) {
      debugPrint('TripNotifier: failed to save trip history — $e');
    });
    _tripStartTime = null;
    _hadAnomaly    = false;
  }

  // ── Public API (unchanged except risk reset on start/end) ───────────────

  void startTripManually() {
    _tripStartTime = DateTime.now();
    _hadAnomaly    = false;
    _resetAnomalyState();
    _resetCheckInState();
    _lastEmittedRiskLevel = RiskLevel.safe;
    state = state.copyWith(
      isTripActive:  true,
      isPaused:      false,
      startPosition: state.currentPosition,
      risk:          RiskSnapshot.idle,
    );
  }

  void endTripManually() {
    _saveTripToHistory();
    _resetAnomalyState();
    _resetCheckInState();
    _lastEmittedRiskLevel = RiskLevel.safe;
    state = state.copyWith(
      isTripActive: false,
      isPaused:     false,
      risk:         RiskSnapshot.idle,
    );
  }

  void pauseTripManually() {
    if (!state.isTripActive) return;
    state = state.copyWith(isPaused: true);
    _lowSpeedSince  = null;
    _stopAlertFired = false;
    debugPrint('Trip paused');
  }

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
    _deviationFired = false;
  }

  void setSource(double lat, double lng, {String label = ''}) {
    state = state.copyWith(sourceLat: lat, sourceLng: lng, sourceLabel: label);
  }
}

// ============================================================================
//  Extension — convenience on RiskLevel (avoids import of risk_engine.dart
//  separately in the UI just for this boolean)
// ============================================================================

extension RiskLevelX on RiskLevel {
  bool get isHighAlert =>
      this == RiskLevel.highRisk || this == RiskLevel.critical;
}

// ============================================================================
//  Provider
// ============================================================================

final tripProvider = NotifierProvider<TripNotifier, TripState>(
  TripNotifier.new,
);
