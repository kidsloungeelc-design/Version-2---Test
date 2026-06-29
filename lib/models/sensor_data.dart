import '../config.dart';

class SensorData {
  final double   left;
  final double   center;
  final double   right;
  final DateTime timestamp;

  const SensorData({
    required this.left,
    required this.center,
    required this.right,
    required this.timestamp,
  });

  factory SensorData.fromSerial(String line) {
    try {
      final parts = line.trim().split(',');
      if (parts.length != 3) throw const FormatException('Need 3 values');
      return SensorData(
        left:      double.parse(parts[0].trim()),
        center:    double.parse(parts[1].trim()),
        right:     double.parse(parts[2].trim()),
        timestamp: DateTime.now(),
      );
    } catch (_) {
      return SensorData(
        left: 400, center: 400, right: 400,
        timestamp: DateTime.now(),
      );
    }
  }

  factory SensorData.empty() => SensorData(
    left: 400, center: 400, right: 400,
    timestamp: DateTime.now(),
  );

  String get closestDirection {
    if (left <= center && left <= right) return 'left';
    if (right <= center) return 'right';
    return 'center';
  }

  String get safeDirection {
    if (left > right + 30)  return 'move left';
    if (right > left + 30)  return 'move right';
    if (center < AppConfig.dangerDistance) return 'stop and wait';
    return 'proceed with caution';
  }

  bool get isCritical => center < AppConfig.criticalDistance;
  bool get isDanger =>
      center < AppConfig.dangerDistance ||
      left   < AppConfig.dangerDistance ||
      right  < AppConfig.dangerDistance;
  bool get isCaution => center < AppConfig.cautionDistance;

  double get minimumDistance =>
      [left, center, right].reduce((a, b) => a < b ? a : b);

  double barValue(double distance) =>
      (1.0 - (distance / 200.0)).clamp(0.0, 1.0);

  double get leftBar   => barValue(left);
  double get centerBar => barValue(center);
  double get rightBar  => barValue(right);
}

/// Tracks whether an external obstacle is moving toward the wearer.
///
/// THE CORE PROBLEM THIS SOLVES:
/// When the wearer walks forward, ALL three sensors decrease together.
/// When an obstacle approaches the wearer while they stand still,
/// only the relevant sensor(s) decrease.
///
/// FIX: We look for cases where center decreases FASTER than
/// left+right average, indicating something coming AT the person
/// rather than the person walking INTO something.
/// We also require CONSISTENCY across multiple frames to avoid
/// noise from a single bumpy step triggering a false alarm.
class VelocityTracker {
  final List<SensorData> _history = [];
  final int maxHistory;

  // How many consecutive frames must agree before we declare approach
  static const int _confirmFrames = 3;

  VelocityTracker({this.maxHistory = 8});

  void add(SensorData data) {
    _history.add(data);
    if (_history.length > maxHistory) _history.removeAt(0);
  }

  /// Raw cm/s of center sensor change.
  /// Positive = distance decreasing = something getting closer.
  double get rawCenterVelocity {
    if (_history.length < 2) return 0.0;
    final oldest = _history.first;
    final newest = _history.last;
    final dt = newest.timestamp
        .difference(oldest.timestamp)
        .inMilliseconds;
    if (dt <= 0) return 0.0;
    return (oldest.center - newest.center) / (dt / 1000.0);
  }

  /// Differential velocity: how much faster center is closing
  /// compared to the average of left+right.
  /// Filters out the wearer's own forward motion.
  double get differentialVelocity {
    if (_history.length < 2) return 0.0;
    final oldest = _history.first;
    final newest = _history.last;
    final dt = newest.timestamp
        .difference(oldest.timestamp)
        .inMilliseconds;
    if (dt <= 0) return 0.0;

    final centerChange =
        (oldest.center - newest.center) / (dt / 1000.0);
    final leftChange   =
        (oldest.left   - newest.left)   / (dt / 1000.0);
    final rightChange  =
        (oldest.right  - newest.right)  / (dt / 1000.0);

    // Average side change represents the wearer moving forward
    final sideAvg = (leftChange + rightChange) / 2.0;

    // Differential: how much more the center is closing vs sides
    // If wearer walks forward, centerChange ≈ sideAvg → differential ≈ 0
    // If object approaches, centerChange >> sideAvg → differential > 0
    return centerChange - sideAvg;
  }

  /// True only if the differential velocity has been consistently
  /// above threshold for multiple frames — rules out single-step noise.
  bool get isApproaching {
    if (_history.length < _confirmFrames + 1) return false;

    // Check that the last N consecutive frame pairs all show approach
    int confirmedFrames = 0;
    for (int i = _history.length - _confirmFrames;
         i < _history.length;
         i++) {
      final prev = _history[i - 1];
      final curr = _history[i];
      final dt   = curr.timestamp
          .difference(prev.timestamp)
          .inMilliseconds;
      if (dt <= 0) continue;

      final cV = (prev.center - curr.center) / (dt / 1000.0);
      final lV = (prev.left   - curr.left)   / (dt / 1000.0);
      final rV = (prev.right  - curr.right)  / (dt / 1000.0);
      final diff = cV - (lV + rV) / 2.0;

      if (diff > AppConfig.movingVelocityThreshold) confirmedFrames++;
    }

    return confirmedFrames >= _confirmFrames - 1;
  }

  bool get isReceding {
    if (_history.length < 2) return false;
    return differentialVelocity < -AppConfig.movingVelocityThreshold;
  }

  bool get isMoving =>
      differentialVelocity.abs() > AppConfig.movingVelocityThreshold;

  String get approachDescription {
    final v = differentialVelocity;
    if (v > 60)  return 'moving toward you quickly';
    if (v > 25)  return 'moving toward you';
    if (v > 10)  return 'moving slowly toward you';
    if (v < -40) return 'moving away quickly';
    if (v < -10) return 'moving away from you';
    return 'stationary';
  }

  // For debug display
  double get debugDifferential => differentialVelocity;
  double get debugRaw          => rawCenterVelocity;

  void clear() => _history.clear();
}
