// lib/services/risk_engine.dart
//
// Pure safety risk engine — no providers, no streams, no side effects.
// Takes a snapshot of current trip conditions and returns a RiskSnapshot.
//
// DESIGN
// ──────
// RiskEngine.evaluate() is called by TripNotifier on each accepted GPS update
// while a trip is active and not paused. Because it is a pure function it is
// trivially testable and can be swapped for a more sophisticated model later
// without touching any UI or provider code.
//
// SCORING (0–100 additive, clamped)
// ──────────────────────────────────
//   Route deviation     0–40 pts  (major signal)
//   Unexpected stop     0–30 pts  (medium signal)
//   Night-time travel   0–15 pts  (minor ambient signal)
//   Paused state         0  pts  (engine not called while paused)
//
// Thresholds → RiskLevel
//   0–25   → Safe
//   26–50  → Caution
//   51–75  → High Risk
//   76–100 → Critical

// ============================================================================
//  RiskLevel
// ============================================================================

enum RiskLevel {
  safe('Safe'),
  caution('Caution'),
  highRisk('High Risk'),
  critical('Critical');

  final String label;
  const RiskLevel(this.label);
}

// ============================================================================
//  RiskSnapshot — immutable value type stored inside TripState
// ============================================================================

class RiskSnapshot {
  /// Composite score 0–100.
  final int score;

  /// Resolved level band.
  final RiskLevel level;

  /// Human-readable primary reason driving this score, shown in the UI.
  /// Empty string when the trip is inactive.
  final String reason;

  /// Timestamp of last computation.
  final DateTime updatedAt;

  const RiskSnapshot({
    required this.score,
    required this.level,
    required this.reason,
    required this.updatedAt,
  });

  /// Default state used before a trip starts.
  static RiskSnapshot get idle => RiskSnapshot(
        score:     0,
        level:     RiskLevel.safe,
        reason:    '',
        updatedAt: DateTime.now(),
      );

  /// True when level warrants a visible warning (shown as a Snackbar).
  bool get isHighAlert =>
      level == RiskLevel.highRisk || level == RiskLevel.critical;
}

// ============================================================================
//  RiskInput — all inputs the engine needs, assembled by TripNotifier
// ============================================================================

class RiskInput {
  /// Perpendicular deviation in metres from the start→destination straight
  /// line. Null when no destination has been set.
  final double? deviationMetres;

  /// Seconds the device has been below the stop-speed threshold continuously.
  /// Zero when the device is moving.
  final int stopDurationSeconds;

  /// Current wall-clock hour (0–23) in local time.
  final int currentHour;

  const RiskInput({
    required this.deviationMetres,
    required this.stopDurationSeconds,
    required this.currentHour,
  });
}

// ============================================================================
//  RiskEngine
// ============================================================================

class RiskEngine {
  // ── Deviation scoring ────────────────────────────────────────────────────
  // 0 m         →  0 pts
  // 250 m       → 15 pts  (half-threshold — visible caution)
  // 500 m       → 30 pts  (existing anomaly threshold)
  // ≥ 1000 m    → 40 pts  (hard cap — severe deviation)
  static const double _devLow  = 250.0;   // starts contributing
  static const double _devMid  = 500.0;   // anomaly threshold
  static const double _devHigh = 1000.0;  // max cap

  // ── Stop scoring ──────────────────────────────────────────────────────────
  // 30 s        →  0 pts  (grace period — matches anomaly timer)
  // 60 s        → 15 pts  (caution territory)
  // 120 s       → 25 pts
  // ≥ 180 s     → 30 pts  (hard cap)
  static const int _stopGrace  = 30;
  static const int _stopMid    = 60;
  static const int _stopHigh   = 120;
  static const int _stopMax    = 180;

  // ── Night hours ───────────────────────────────────────────────────────────
  // 23:00–05:59 → 15 pts
  // 22:00–22:59 → 8  pts  (shoulder hours)
  // all else    →  0 pts

  const RiskEngine();

  /// Evaluate all risk signals and return an immutable [RiskSnapshot].
  RiskSnapshot evaluate(RiskInput input) {
    int score = 0;
    final reasons = <String>[];

    // ── 1. Route deviation ───────────────────────────────────────────────
    final dev = input.deviationMetres;
    if (dev != null) {
      if (dev >= _devHigh) {
        score += 40;
        reasons.add('Severe route deviation');
      } else if (dev >= _devMid) {
        // Linear between _devMid(30) and _devHigh(40)
        final extra = ((dev - _devMid) / (_devHigh - _devMid) * 10).round();
        score += 30 + extra;
        reasons.add('Route deviation detected');
      } else if (dev >= _devLow) {
        // Linear between _devLow(0) and _devMid(30)
        final pts = ((dev - _devLow) / (_devMid - _devLow) * 30).round();
        score += pts;
        if (pts >= 10) reasons.add('Slight route deviation');
      }
    }

    // ── 2. Unexpected stop ───────────────────────────────────────────────
    final stop = input.stopDurationSeconds;
    if (stop > _stopGrace) {
      if (stop >= _stopMax) {
        score += 30;
        reasons.add('Prolonged stop detected');
      } else if (stop >= _stopHigh) {
        score += 25;
        reasons.add('Extended stop detected');
      } else if (stop >= _stopMid) {
        score += 15;
        reasons.add('Unexpected stop detected');
      } else {
        // Linear between _stopGrace(0) and _stopMid(15)
        final pts = ((stop - _stopGrace) / (_stopMid - _stopGrace) * 15).round();
        score += pts;
      }
    }

    // ── 3. Night-time travel ─────────────────────────────────────────────
    final h = input.currentHour;
    if (h >= 23 || h < 6) {
      score += 15;
      reasons.add('Late-night trip');
    } else if (h == 22) {
      score += 8;
      if (score > 25) reasons.add('Late-evening trip');
    }

    // ── Clamp and classify ────────────────────────────────────────────────
    final clamped = score.clamp(0, 100);
    final level   = _classify(clamped);
    final reason  = reasons.isNotEmpty ? reasons.first : 'Normal conditions';

    return RiskSnapshot(
      score:     clamped,
      level:     level,
      reason:    reason,
      updatedAt: DateTime.now(),
    );
  }

  static RiskLevel _classify(int score) {
    if (score >= 76) return RiskLevel.critical;
    if (score >= 51) return RiskLevel.highRisk;
    if (score >= 26) return RiskLevel.caution;
    return RiskLevel.safe;
  }
}
