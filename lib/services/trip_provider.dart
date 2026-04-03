import 'dart:async';
import 'package:flutter/foundation.dart';
import 'dart:math';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';
import 'location_service.dart';
import 'trip_history_service.dart';

class TripState {
  final bool isTripActive;
  final bool isPaused;
  final Position? currentPosition;
  final Position? startPosition;
  final double sourceLat;
  final double sourceLng;
  final String sourceLabel;
  final double destinationLat;
  final double destinationLng;
  final String destinationLabel;

  const TripState({
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
  });

  bool get hasSource      => sourceLat != 0.0 || sourceLng != 0.0;
  bool get hasDestination => destinationLat != 0.0 || destinationLng != 0.0;

  TripState copyWith({
    bool?     isTripActive,
    bool?     isPaused,
    Position? currentPosition,
    Position? startPosition,
    double?   sourceLat,
    double?   sourceLng,
    String?   sourceLabel,
    double?   destinationLat,
    double?   destinationLng,
    String?   destinationLabel,
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
    );
  }

  double? get distanceToDestinationMetres {
    if (currentPosition == null || !hasDestination) return null;
    return Geolocator.distanceBetween(
      currentPosition!.latitude,  currentPosition!.longitude,
      destinationLat,              destinationLng,
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
    return (bx * py - by * px).abs() / sqrt(ab2);
  }
}

class TripNotifier extends Notifier<TripState> {
  StreamSubscription<Position>? _positionSub;
  Position? _lastAcceptedPosition;
  int _consecutiveGoodUpdates = 0;
  DateTime? _lowSpeedSince;
  bool _stopAlertFired  = false;
  bool _deviationFired  = false;
  DateTime? _tripStartTime;
  bool _hadAnomaly = false;

  static const double _speedCheckInKmh           = 5.0;
  static const double _checkInMovementM           = 20.0;
  static const double _jitterFilterM              = 10.0;
  static const int    _requiredConsecutiveUpdates = 2;
  static const double _checkOutRadiusM            = 80.0;
  static const double _stopSpeedKmh               = 2.0;
  static const int    _stopSeconds                = 30;
  static const double _deviationThresholdM        = 500.0;

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

  void _startMonitoring(LocationService locationService) {
    _positionSub?.cancel();
    _positionSub = locationService.positionStream.listen(
      _onPosition,
      onError: (_) {},
      cancelOnError: false,
    );
  }

  void _onPosition(Position position) {
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

    if (!state.isTripActive) {
      if (_shouldAutoCheckIn(position)) {
        _tripStartTime = DateTime.now();
        _hadAnomaly    = false;
        _consecutiveGoodUpdates = 0;
        state = state.copyWith(isTripActive: true, isPaused: false, startPosition: position);
        debugPrint('Trip started automatically');
      }
      return;
    }

    if (state.isPaused) return;

    if (state.hasDestination) {
      final dist = state.distanceToDestinationMetres;
      if (dist != null && dist < _checkOutRadiusM) {
        _saveTripToHistory();
        state = state.copyWith(isTripActive: false, isPaused: false);
        debugPrint('Trip ended automatically');
        _lastAcceptedPosition = null;
        _consecutiveGoodUpdates = 0;
        _resetAnomalyState();
        return;
      }
    }
    _detectSuddenStop(position);
    if (state.hasDestination) _detectRouteDeviation();
  }

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
      if (DateTime.now().difference(_lowSpeedSince!).inSeconds >= _stopSeconds && !_stopAlertFired) {
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
      id:       '',
      startedAt: _tripStartTime!,
      endedAt:   DateTime.now(),
      startLat:  state.startPosition!.latitude,
      startLng:  state.startPosition!.longitude,
      endLat:    state.currentPosition!.latitude,
      endLng:    state.currentPosition!.longitude,
      distanceTravelledKm: Geolocator.distanceBetween(
        state.startPosition!.latitude,  state.startPosition!.longitude,
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

  void endTripManually() {
    _saveTripToHistory();
    state = state.copyWith(isTripActive: false, isPaused: false);
    _resetAnomalyState();
    _resetCheckInState();
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
    state = state.copyWith(destinationLat: lat, destinationLng: lng, destinationLabel: label);
    _deviationFired = false;
  }

  void setSource(double lat, double lng, {String label = ''}) {
    state = state.copyWith(sourceLat: lat, sourceLng: lng, sourceLabel: label);
  }
}

final tripProvider = NotifierProvider<TripNotifier, TripState>(TripNotifier.new);
