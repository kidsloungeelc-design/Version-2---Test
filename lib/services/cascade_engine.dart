import 'dart:async';
import 'dart:typed_data';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';
import '../config.dart';
import 'gemini_service.dart';
import 'tts_service.dart';
import 'scene_description_service.dart';

class CascadeEngine {
  final GeminiService           _gemini    = GeminiService();
  final TtsService              _tts;
  final SceneDescriptionService _sceneDesc = SceneDescriptionService();
  final VelocityTracker         _velocity  = VelocityTracker();

  // ── Frame counters ────────────────────────────────────────────────────
  int totalFrames      = 0;
  int gateCalledCount  = 0;
  int gateYesCount     = 0;
  int classifyCount    = 0;
  int safetyCount      = 0;
  int sensorOnlyCount  = 0;
  int apiErrorCount    = 0;

  // ── Importance ranking counters ───────────────────────────────────────
  int criticalCueCount = 0;
  int highCueCount     = 0;
  int mediumCueCount   = 0;
  int lowCueCount      = 0;

  // ── Object type counters ──────────────────────────────────────────────
  int personCount      = 0;
  int furnitureCount   = 0;
  int doorCount        = 0;
  int stairsCount      = 0;
  int petCount         = 0;
  int otherCount       = 0;

  // ── Velocity counters ─────────────────────────────────────────────────
  int movingObjectCount    = 0;
  int approachingCount     = 0;
  int recedingCount        = 0;

  // ── Latency tracking ─────────────────────────────────────────────────
  final List<int> _gateLatencies     = [];
  final List<int> _classifyLatencies = [];

  // ── State ─────────────────────────────────────────────────────────────
  SensorData?      lastSensors;
  GateResult?      lastGate;
  DetectionResult? lastDetection;
  NavCue?          lastCue;

  CascadeEngine({required TtsService tts}) : _tts = tts;

  Future<NavCue> process(SensorData sensors, Uint8List? frameBytes) async {
    final sw = Stopwatch()..start();
    lastSensors = sensors;
    totalFrames++;

    // Update velocity tracker every frame
    _velocity.add(sensors);

    // ── SAFETY LAYER — always first, no AI ───────────────────────────
    if (sensors.isCritical) {
      safetyCount++;
      criticalCueCount++;

      String safetyText;
      if (_velocity.isApproaching) {
        safetyText = 'Stop! Something is approaching fast, '
                     '${sensors.center.round()} centimetres ahead.';
      } else {
        safetyText = 'Stop! Obstacle ${sensors.center.round()} '
                     'centimetres directly ahead.';
      }

      await _tts.speakUrgent(safetyText);
      sw.stop();
      final cue = NavCue(
        text:           safetyText,
        source:         CueSource.safety,
        direction:      'stop',
        obstacleLabel:  'obstacle',
        environment:    EnvironmentInfo.empty(),
        urgency:        'critical',
        timestamp:      DateTime.now(),
        totalLatencyMs: sw.elapsedMilliseconds,
      );
      lastCue = cue;
      return cue;
    }

    // ── SENSOR ONLY — no frame or no API key ─────────────────────────
    if (!sensors.isDanger || frameBytes == null || !AppConfig.isApiKeySet) {
      sensorOnlyCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      if (sensors.isCaution) {
        await _tts.speak(cue.text, priority: TtsPriority.medium);
      }
      return cue;
    }

    // ── STAGE 1: GATE ─────────────────────────────────────────────────
    gateCalledCount++;
    final gate = await _gemini.runGate(frameBytes);
    lastGate = gate;
    _gateLatencies.add(gate.latencyMs);
    if (_gateLatencies.length > 50) _gateLatencies.removeAt(0);

    if (!gate.obstacleDetected) {
      sensorOnlyCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      if (sensors.isCaution) {
        await _tts.speak(cue.text, priority: TtsPriority.low);
      }
      _checkAndFireSceneDescription(sensors, frameBytes);
      return cue;
    }

    gateYesCount++;

    // ── STAGE 2: CLASSIFY ─────────────────────────────────────────────
    classifyCount++;
    final detection = await _gemini.classify(frameBytes);
    lastDetection   = detection;
    _classifyLatencies.add(detection.latencyMs);
    if (_classifyLatencies.length > 50) _classifyLatencies.removeAt(0);
    sw.stop();

    if (!detection.success) {
      apiErrorCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      await _tts.speak(cue.text, priority: TtsPriority.medium);
      return cue;
    }

    // Update object type counters
    _updateObjectCounters(detection.label);

    // Update velocity counters
    if (_velocity.isMoving) movingObjectCount++;
    if (_velocity.isApproaching) approachingCount++;
    if (_velocity.isReceding) recedingCount++;

    // Build rich cue with importance ranking
    final priority = _importancePriority(detection, sensors);
    final cue      = _buildRichCue(
        detection, sensors, sw.elapsedMilliseconds, priority);
    lastCue = cue;

    // Update importance counters
    switch (priority) {
      case TtsPriority.critical: criticalCueCount++; break;
      case TtsPriority.high:     highCueCount++;     break;
      case TtsPriority.medium:   mediumCueCount++;   break;
      case TtsPriority.low:      lowCueCount++;      break;
    }

    await _tts.speak(cue.text, priority: priority);
    _checkAndFireSceneDescription(sensors, frameBytes);

    return cue;
  }

  /// Rank importance of detected obstacle to prioritise TTS.
  TtsPriority _importancePriority(
      DetectionResult det, SensorData sensors) {

    // Critical — stairs down or very close moving person
    if (det.label == ObstacleLabel.stairs_down ||
        det.label == ObstacleLabel.step_down) {
      return TtsPriority.critical;
    }

    if (det.urgency == 'critical') return TtsPriority.critical;

    // High — approaching person/pet, close obstacle, open stairs
    if (_velocity.isApproaching &&
        (det.label == ObstacleLabel.person ||
         det.label == ObstacleLabel.animal ||
         det.label == ObstacleLabel.child)) {
      return TtsPriority.critical;
    }

    if (det.urgency == 'high' ||
        det.label == ObstacleLabel.stairs_up ||
        det.label == ObstacleLabel.wet_floor ||
        det.label == ObstacleLabel.glass_door ||
        sensors.center < 60) {
      return TtsPriority.high;
    }

    // Medium — furniture, doors, narrow passages
    if (det.label == ObstacleLabel.door_open   ||
        det.label == ObstacleLabel.door_closed  ||
        det.label == ObstacleLabel.chair        ||
        det.label == ObstacleLabel.table        ||
        det.label == ObstacleLabel.sofa         ||
        det.label == ObstacleLabel.narrow_passage) {
      return TtsPriority.medium;
    }

    // Low — peripheral, far, or already described
    if (det.distanceEstimate == 'far' || det.distanceEstimate == 'ahead') {
      return TtsPriority.low;
    }

    return TtsPriority.medium;
  }

  NavCue _buildRichCue(
      DetectionResult det,
      SensorData sensors,
      int latencyMs,
      TtsPriority priority) {

    // Use Gemini's navigation_instruction if it's good
    String cueText = det.navigationInstruction;

    if (cueText.isEmpty || cueText == 'null') {
      cueText = _buildInstructionFromData(det, sensors);
    }

    // Prepend urgency prefix
    if (det.urgency == 'critical') {
      cueText = 'Warning. $cueText';
    } else if (_velocity.isApproaching &&
        (det.label == ObstacleLabel.person ||
         det.label == ObstacleLabel.animal ||
         det.label == ObstacleLabel.child)) {
      cueText = 'Caution — ${_velocity.approachDescription}. $cueText';
    }

    // Add sensor distance for close obstacles
    if (sensors.center < AppConfig.dangerDistance) {
      final dist = sensors.center.round();
      cueText = '$cueText ($dist cm)';
    }

    return NavCue(
      text:           cueText,
      source:         CueSource.gemini,
      direction:      _extractDirection(det),
      obstacleLabel:  det.label.name,
      environment:    det.environment,
      urgency:        det.urgency,
      timestamp:      DateTime.now(),
      totalLatencyMs: latencyMs,
    );
  }

  String _buildInstructionFromData(
      DetectionResult det, SensorData sensors) {
    final label     = _labelText(det.label);
    final specifics = det.specifics.isNotEmpty ? det.specifics : label;
    final position  = _positionText(det.position);
    final distance  = det.distanceEstimate;
    final direction = _safeDirectionFromSensors(sensors);

    // Moving person/animal — use velocity
    if ((det.label == ObstacleLabel.person  ||
         det.label == ObstacleLabel.child   ||
         det.label == ObstacleLabel.animal) &&
        _velocity.isMoving) {
      final velDesc = _velocity.approachDescription;
      if (_velocity.isApproaching) {
        return 'A $specifics is $velDesc from $position. '
               'Stop and wait for them to pass.';
      } else if (_velocity.isReceding) {
        return 'A $specifics ahead is moving away. '
               'You may proceed carefully.';
      }
    }

    // Stairs — always specific and directional
    if (det.label == ObstacleLabel.stairs_down ||
        det.label == ObstacleLabel.step_down) {
      return 'Stairs going down $position, $distance. '
             'Stop and find the handrail before proceeding.';
    }
    if (det.label == ObstacleLabel.stairs_up ||
        det.label == ObstacleLabel.step_up) {
      return 'Stairs going up $position, $distance. '
             'Approach carefully and find the handrail.';
    }

    // Doors
    if (det.label == ObstacleLabel.door_open) {
      return 'Open door $position, $distance. You can pass through.';
    }
    if (det.label == ObstacleLabel.door_closed) {
      return 'Closed door directly $position, $distance. '
             'Reach forward to open it.';
    }
    if (det.label == ObstacleLabel.glass_door) {
      return 'Glass door $position, $distance. '
             'Proceed carefully — it may be hard to see.';
    }

    // Wet floor
    if (det.label == ObstacleLabel.wet_floor) {
      return 'Wet floor $position. Walk carefully to avoid slipping.';
    }

    // Narrow passage
    if (det.label == ObstacleLabel.narrow_passage) {
      return 'Narrow passage $position. '
             'Move to the centre and proceed slowly.';
    }

    // Group of people
    if (det.label == ObstacleLabel.group_of_people) {
      return 'Group of people $distance $position. '
             '$direction to go around them.';
    }

    // Furniture
    if (det.label == ObstacleLabel.chair ||
        det.label == ObstacleLabel.table ||
        det.label == ObstacleLabel.sofa  ||
        det.label == ObstacleLabel.desk) {
      return 'A $specifics is $distance $position. $direction.';
    }

    return 'A $specifics is $distance $position. $direction.';
  }

  NavCue _buildSensorCue(SensorData sensors, int latencyMs) {
    String text;
    String direction;
    TtsPriority priority;

    final dist = sensors.center.round();

    if (sensors.center < 40) {
      text      = 'Stop immediately. Something is ${dist} centimetres '
                  'directly in front of you.';
      direction = 'stop';
      priority  = TtsPriority.critical;
    } else if (sensors.center < 80) {
      direction = sensors.safeDirection;
      final velNote = _velocity.isApproaching
          ? ' It appears to be approaching.'
          : '';
      text     = 'Obstacle ${dist} centimetres ahead.$velNote $direction.';
      priority = TtsPriority.high;
    } else if (sensors.left < 60) {
      direction = 'move right';
      text      = 'Something very close on your left, '
                  '${sensors.left.round()} centimetres. Move to your right.';
      priority  = TtsPriority.high;
    } else if (sensors.right < 60) {
      direction = 'move left';
      text      = 'Something very close on your right, '
                  '${sensors.right.round()} centimetres. Move to your left.';
      priority  = TtsPriority.high;
    } else if (sensors.left < 100) {
      direction = 'move slightly right';
      text      = 'Object on your left. Drift slightly to your right.';
      priority  = TtsPriority.medium;
    } else if (sensors.right < 100) {
      direction = 'move slightly left';
      text      = 'Object on your right. Drift slightly to your left.';
      priority  = TtsPriority.medium;
    } else {
      direction = 'proceed';
      text      = 'Path is clear. Continue forward.';
      priority  = TtsPriority.low;
    }

    // Track importance
    switch (priority) {
      case TtsPriority.critical: criticalCueCount++; break;
      case TtsPriority.high:     highCueCount++;     break;
      case TtsPriority.medium:   mediumCueCount++;   break;
      case TtsPriority.low:      lowCueCount++;      break;
    }

    return NavCue(
      text:           text,
      source:         CueSource.sensor,
      direction:      direction,
      obstacleLabel:  'obstacle',
      environment:    EnvironmentInfo.empty(),
      urgency:        sensors.center < 80 ? 'high' : 'low',
      timestamp:      DateTime.now(),
      totalLatencyMs: latencyMs,
    );
  }

  void _checkAndFireSceneDescription(
      SensorData sensors, Uint8List frameBytes) {
    final triggerReason = _sceneDesc.checkTriggers(
      sensors:       sensors,
      lastGate:      lastGate,
      lastDetection: lastDetection,
      velocity:      _velocity,
    );

    if (triggerReason != null) {
      _sceneDesc.describe(frameBytes, triggerReason).then((description) {
        if (description != null && description.isNotEmpty) {
          Future.delayed(
            Duration(milliseconds: AppConfig.ttsSceneDescCooldownMs),
            () => _tts.speak(description, priority: TtsPriority.low),
          );
        }
      });
    }
  }

  void _updateObjectCounters(ObstacleLabel label) {
    switch (label) {
      case ObstacleLabel.person:
      case ObstacleLabel.group_of_people:
      case ObstacleLabel.child:
        personCount++;
        break;
      case ObstacleLabel.animal:
        petCount++;
        break;
      case ObstacleLabel.chair:
      case ObstacleLabel.table:
      case ObstacleLabel.sofa:
      case ObstacleLabel.desk:
      case ObstacleLabel.bed:
      case ObstacleLabel.shelf:
      case ObstacleLabel.counter:
        furnitureCount++;
        break;
      case ObstacleLabel.door_open:
      case ObstacleLabel.door_closed:
      case ObstacleLabel.glass_door:
        doorCount++;
        break;
      case ObstacleLabel.stairs_up:
      case ObstacleLabel.stairs_down:
      case ObstacleLabel.step_up:
      case ObstacleLabel.step_down:
        stairsCount++;
        break;
      default:
        otherCount++;
    }
  }

  String _safeDirectionFromSensors(SensorData sensors) {
    if (sensors.left > sensors.right + 40) return 'Move to your left';
    if (sensors.right > sensors.left + 40) return 'Move to your right';
    if (sensors.center < 80) return 'Stop and wait';
    return 'Proceed with caution';
  }

  String _extractDirection(DetectionResult det) {
    final instruction = det.navigationInstruction.toLowerCase();
    if (instruction.contains('move left')  ||
        instruction.contains('step left')  ||
        instruction.contains('go left'))   return 'left';
    if (instruction.contains('move right') ||
        instruction.contains('step right') ||
        instruction.contains('go right'))  return 'right';
    if (instruction.contains('stop') ||
        instruction.contains('wait'))      return 'stop';
    return 'forward';
  }

  String _labelText(ObstacleLabel label) {
    const m = {
      ObstacleLabel.person:          'person',
      ObstacleLabel.group_of_people: 'group of people',
      ObstacleLabel.child:           'child',
      ObstacleLabel.animal:          'animal',
      ObstacleLabel.chair:           'chair',
      ObstacleLabel.table:           'table',
      ObstacleLabel.sofa:            'sofa',
      ObstacleLabel.desk:            'desk',
      ObstacleLabel.bed:             'bed',
      ObstacleLabel.door_open:       'open door',
      ObstacleLabel.door_closed:     'closed door',
      ObstacleLabel.stairs_up:       'stairs going up',
      ObstacleLabel.stairs_down:     'stairs going down',
      ObstacleLabel.step_up:         'step up',
      ObstacleLabel.step_down:       'step down',
      ObstacleLabel.wall:            'wall',
      ObstacleLabel.pillar:          'pillar',
      ObstacleLabel.glass_door:      'glass door',
      ObstacleLabel.vehicle:         'vehicle',
      ObstacleLabel.bicycle:         'bicycle',
      ObstacleLabel.shopping_cart:   'shopping cart',
      ObstacleLabel.trolley:         'trolley',
      ObstacleLabel.wet_floor:       'wet floor',
      ObstacleLabel.narrow_passage:  'narrow passage',
      ObstacleLabel.counter:         'counter',
      ObstacleLabel.shelf:           'shelf',
      ObstacleLabel.clear:           'clear path',
      ObstacleLabel.unknown:         'obstacle',
    };
    return m[label] ?? 'obstacle';
  }

  String _positionText(ObstaclePosition pos) {
    const m = {
      ObstaclePosition.left:    'on your left',
      ObstaclePosition.center:  'directly ahead',
      ObstaclePosition.right:   'on your right',
      ObstaclePosition.unclear: 'nearby',
    };
    return m[pos] ?? 'ahead';
  }

  // ── Stats ─────────────────────────────────────────────────────────────

  double get apiSavingPercent =>
      totalFrames > 0
          ? (1.0 - classifyCount / totalFrames) * 100.0
          : 0.0;

  double get gateTriggerPercent =>
      totalFrames > 0 ? gateYesCount / totalFrames * 100.0 : 0.0;

  int get avgGateLatencyMs =>
      _gateLatencies.isEmpty ? 0
          : (_gateLatencies.reduce((a, b) => a + b) /
              _gateLatencies.length).round();

  int get avgClassifyLatencyMs =>
      _classifyLatencies.isEmpty ? 0
          : (_classifyLatencies.reduce((a, b) => a + b) /
              _classifyLatencies.length).round();

  SceneDescriptionService get sceneDescService => _sceneDesc;
  String get lastSceneDescription => _sceneDesc.lastDescription;

  Map<String, dynamic> toStats() => {
    'total_frames':          totalFrames,
    'gate_called':           gateCalledCount,
    'gate_yes':              gateYesCount,
    'classify_called':       classifyCount,
    'sensor_only':           sensorOnlyCount,
    'safety_overrides':      safetyCount,
    'api_errors':            apiErrorCount,
    'api_saving_percent':    apiSavingPercent.toStringAsFixed(1),
    'gate_trigger_percent':  gateTriggerPercent.toStringAsFixed(1),
    'avg_gate_latency_ms':   avgGateLatencyMs,
    'avg_classify_latency_ms': avgClassifyLatencyMs,
    'importance': {
      'critical': criticalCueCount,
      'high':     highCueCount,
      'medium':   mediumCueCount,
      'low':      lowCueCount,
    },
    'objects': {
      'person':    personCount,
      'pet':       petCount,
      'furniture': furnitureCount,
      'door':      doorCount,
      'stairs':    stairsCount,
      'other':     otherCount,
    },
    'velocity': {
      'moving':     movingObjectCount,
      'approaching': approachingCount,
      'receding':   recedingCount,
    },
    'tts': _tts.stats,
  };
}


