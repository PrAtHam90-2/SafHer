// lib/services/trip_history_service.dart
//
// Firestore-backed trip history.
// Collection path: users/{uid}/trips/{tripId}
//
// INTEGRATION STEPS:
//   1. In TripNotifier.endTripManually() (and the auto-checkout block), call:
//        ref.read(tripHistoryServiceProvider).saveTrip(TripRecord(...))
//      before resetting state.
//   2. On HomeScreen, watch tripHistoryProvider to show recent trips.
//
// FIRESTORE INDEXES NEEDED:
//   Collection: users/{uid}/trips
//   Composite index: startedAt DESC (for the orderBy below)
//   Firestore will prompt you to create this on the first query.

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ============================================================================
//  TripRecord model
// ============================================================================

class TripRecord {
  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final double startLat;
  final double startLng;
  final double endLat;
  final double endLng;
  final double distanceTravelledKm;
  final bool hadAnomaly;

  const TripRecord({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.startLat,
    required this.startLng,
    required this.endLat,
    required this.endLng,
    required this.distanceTravelledKm,
    required this.hadAnomaly,
  });

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toMap() => {
    'startedAt':           Timestamp.fromDate(startedAt),
    'endedAt':             Timestamp.fromDate(endedAt),
    'startLat':            startLat,
    'startLng':            startLng,
    'endLat':              endLat,
    'endLng':              endLng,
    'distanceTravelledKm': distanceTravelledKm,
    'hadAnomaly':          hadAnomaly,
  };

  factory TripRecord.fromFirestore(String docId, Map<String, dynamic> data) {
    return TripRecord(
      id:                   docId,
      startedAt:            (data['startedAt'] as Timestamp).toDate(),
      endedAt:              (data['endedAt'] as Timestamp).toDate(),
      startLat:             (data['startLat'] as num).toDouble(),
      startLng:             (data['startLng'] as num).toDouble(),
      endLat:               (data['endLat'] as num).toDouble(),
      endLng:               (data['endLng'] as num).toDouble(),
      distanceTravelledKm:  (data['distanceTravelledKm'] as num).toDouble(),
      hadAnomaly:           (data['hadAnomaly'] as bool?) ?? false,
    );
  }
}

// ============================================================================
//  TripHistoryService
// ============================================================================

class TripHistoryService {
  final FirebaseFirestore _db;

  TripHistoryService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> _col(String uid) =>
      _db.collection('users').doc(uid).collection('trips');

  /// Persist a completed trip. Returns the new document ID.
  Future<String> saveTrip(TripRecord record) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('User not logged in');

    final doc = await _col(uid).add(record.toMap());
    return doc.id;
  }

  /// Fetch the [limit] most recent trips for the current user.
  Future<List<TripRecord>> recentTrips({int limit = 10}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return [];

    final snap = await _col(uid)
        .orderBy('startedAt', descending: true)
        .limit(limit)
        .get();

    return snap.docs
        .map((d) => TripRecord.fromFirestore(d.id, d.data()))
        .toList();
  }
}

// ============================================================================
//  Providers
// ============================================================================

final tripHistoryServiceProvider = Provider<TripHistoryService>((ref) {
  return TripHistoryService();
});

/// Watches the [limit] most recent trips — refreshed on demand via
/// ref.invalidate(tripHistoryProvider).
final tripHistoryProvider =
    FutureProvider.autoDispose<List<TripRecord>>((ref) async {
  return ref.read(tripHistoryServiceProvider).recentTrips(limit: 10);
});

// ============================================================================
//  Integration helper — call this from TripNotifier when ending a trip
// ============================================================================
//
// In trip_provider.dart, add the following to _onPosition (auto checkout)
// and endTripManually():
//
//   Future<void> _saveTripToHistory({required bool hadAnomaly}) async {
//     if (state.startPosition == null || state.currentPosition == null) return;
//     final record = TripRecord(
//       id: '',   // Firestore will assign
//       startedAt: _tripStartTime!,
//       endedAt: DateTime.now(),
//       startLat: state.startPosition!.latitude,
//       startLng: state.startPosition!.longitude,
//       endLat: state.currentPosition!.latitude,
//       endLng: state.currentPosition!.longitude,
//       distanceTravelledKm: Geolocator.distanceBetween(
//         state.startPosition!.latitude, state.startPosition!.longitude,
//         state.currentPosition!.latitude, state.currentPosition!.longitude,
//       ) / 1000,
//       hadAnomaly: hadAnomaly,
//     );
//     await ref.read(tripHistoryServiceProvider).saveTrip(record);
//     ref.invalidate(tripHistoryProvider);  // refresh the list on HomeScreen
//   }
//
// You'll also need to add:
//   DateTime? _tripStartTime;   // set in startTripManually() and auto check-in
//   bool _hadAnomaly = false;   // set to true in _anomalyController.add(...)
