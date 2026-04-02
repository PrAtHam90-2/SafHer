import 'dart:math';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

// ============================================================================
//  DriverStatus — resolved from BOTH verified (bool) + Status (string)
// ============================================================================

enum DriverStatus { active, expired, suspended, notFound, unknown }

extension DriverStatusX on DriverStatus {
  /// Resolves status from the two Firestore fields.
  ///
  /// Rules (Part 1):
  ///   verified=true  + active    → DriverStatus.active
  ///   verified=true  + expired   → DriverStatus.expired   (orange badge)
  ///   any            + suspended → DriverStatus.suspended  (red badge)
  ///   verified=false + any       → DriverStatus.unknown    (red badge)
  static DriverStatus resolve({
    required bool verified,
    required String rawStatus,
  }) {
    final s = rawStatus.toLowerCase().trim();
    if (s == 'suspended') return DriverStatus.suspended;
    if (!verified)        return DriverStatus.unknown;
    return switch (s) {
      'active'  => DriverStatus.active,
      'expired' => DriverStatus.expired,
      _         => DriverStatus.unknown,
    };
  }

  /// Badge label shown in the header card (Part 1).
  String get badgeLabel => switch (this) {
        DriverStatus.active    => 'IDENTITY\nVERIFIED',
        DriverStatus.suspended => 'SUSPENDED',
        DriverStatus.expired   => 'DOCS\nEXPIRED',   // verified but expired
        _                      => 'NOT\nVERIFIED',
      };

  /// Drives the Background Check row colour (Part 4).
  BgCheckState get bgCheckState => switch (this) {
        DriverStatus.active    => BgCheckState.safe,
        DriverStatus.expired   => BgCheckState.warning,
        DriverStatus.suspended => BgCheckState.danger,
        _                      => BgCheckState.danger,
      };
}

// ============================================================================
//  BgCheckState
// ============================================================================

enum BgCheckState { safe, warning, danger }

// ============================================================================
//  VerificationData
// ============================================================================

class VerificationData {
  // ── Raw Firestore fields ──────────────────────────────────────────────────
  final String driverName;
  final String vehicleNumber;
  final String vehicleModel;     // Part 2
  final String licenseNumber;
  final String phone;
  final DriverStatus driverStatus;

  // ── Derived UI fields ─────────────────────────────────────────────────────
  final String vehicleInfo;      // "MH12AB1234 • Alto"
  final int    safetyScore;
  final String safetyScoreLabel;

  const VerificationData({
    required this.driverName,
    required this.vehicleNumber,
    required this.vehicleModel,
    required this.licenseNumber,
    required this.phone,
    required this.driverStatus,
    required this.vehicleInfo,
    required this.safetyScore,
    required this.safetyScoreLabel,
  });

  // ── Convenience getters consumed by the screen ────────────────────────────
  bool get isActive         => driverStatus == DriverStatus.active;
  BgCheckState get bgCheckState => driverStatus.bgCheckState;
  bool get licenseVerified  => licenseNumber.isNotEmpty;

  // ── Factory: Firestore document found (Part 6 — safe parsing) ────────────
  factory VerificationData.fromFirestore(
    String vehicleNumber,
    Map<String, dynamic> doc,
  ) {
    // Safe field parsing — every field uses ?. + toString() + fallback
    final driverName   = doc['driverName']?.toString()  ?? 'Unknown Driver';
    final vehicleModel = doc['vehicleModel']?.toString() ?? 'Unknown';
    final licenseNum   = doc['licenseNumber']?.toString() ?? '';
    final phone        = doc['phone']?.toString()         ?? '';

    // Part 1 — read BOTH fields
    final verified  = (doc['verified'] as bool?) ?? false;
    final rawStatus = doc['Status']?.toString() ?? 'unknown'; // capital S

    final status = DriverStatusX.resolve(
      verified:  verified,
      rawStatus: rawStatus,
    );

    return VerificationData(
      driverName:       driverName,
      vehicleNumber:    vehicleNumber,
      vehicleModel:     vehicleModel,
      licenseNumber:    licenseNum,
      phone:            phone,
      driverStatus:     status,
      vehicleInfo:      '$vehicleNumber • $vehicleModel',   // Part 2
      safetyScore:      _computeSafetyScore(vehicleNumber, status),
      safetyScoreLabel: _safetyLabel(status),
    );
  }

  // ── Factory: document not found ───────────────────────────────────────────
  factory VerificationData.notFound(String vehicleNumber) {
    return VerificationData(
      driverName:       'Unknown Driver',
      vehicleNumber:    vehicleNumber,
      vehicleModel:     'Unknown',
      licenseNumber:    '',
      phone:            '',
      driverStatus:     DriverStatus.notFound,
      vehicleInfo:      '$vehicleNumber • NOT FOUND',
      safetyScore:      0,
      safetyScoreLabel: 'Unknown — vehicle not in database.',
    );
  }

  // ── Deterministic score (same plate → same score every time) ─────────────
  static int _computeSafetyScore(String vehicleNumber, DriverStatus status) {
    final seed = vehicleNumber.codeUnits.fold(0, (a, b) => a + b);
    final rng  = Random(seed);
    return switch (status) {
      DriverStatus.active    => 80 + rng.nextInt(16), // 80–95
      DriverStatus.expired   => 60 + rng.nextInt(16), // 60–75
      DriverStatus.suspended => 20 + rng.nextInt(31), // 20–50
      _                      => 10 + rng.nextInt(11), // 10–20
    };
  }

  static String _safetyLabel(DriverStatus status) => switch (status) {
        DriverStatus.active    => 'Safe — verified driver.',
        DriverStatus.expired   => 'Moderate — documents expired.',
        DriverStatus.suspended => 'High Risk — flagged driver.',
        _                      => 'Unknown — vehicle not found.',
      };
}

// ============================================================================
//  VerificationService
// ============================================================================

class VerificationService {
  final FirebaseFirestore _db;

  VerificationService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  Future<VerificationData> verifyByVehicleNumber(String rawInput) async {
    final vehicleNumber = rawInput.trim().toUpperCase();
    final doc = await _db.collection('drivers').doc(vehicleNumber).get();
    if (!doc.exists || doc.data() == null) {
      return VerificationData.notFound(vehicleNumber);
    }
    return VerificationData.fromFirestore(vehicleNumber, doc.data()!);
  }
}

// ============================================================================
//  VerifyNotifier
// ============================================================================

class VerifyNotifier extends AsyncNotifier<VerificationData?> {
  @override
  Future<VerificationData?> build() async => null;

  Future<void> verify(String vehicleNumber) async {
    if (vehicleNumber.trim().isEmpty) return;
    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref
          .read(verificationServiceProvider)
          .verifyByVehicleNumber(vehicleNumber),
    );
  }

  void reset() => state = const AsyncData(null);
}

// ============================================================================
//  Providers
// ============================================================================

final verificationServiceProvider = Provider<VerificationService>((ref) {
  return VerificationService();
});

final verifyProvider =
    AsyncNotifierProvider<VerifyNotifier, VerificationData?>(VerifyNotifier.new);
