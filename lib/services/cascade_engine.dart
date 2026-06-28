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
  final TtsService               _tts;
  final SceneDescriptionService _sceneDesc = SceneDescriptionService();

  // ── Research counters (shown on Results screen) ───────────────────────
  int totalFrames     = 0;
  int gateCalledCount = 0;   // Stage 1 calls
  int gateYesCount    = 0;   // Stage 1 returned YES
  int classifyCount   = 0;   // Stage 2 calls (only when gate said YES)
  int safetyCount     = 0;   // Safety override fires
  int sensorOnlyCount = 0;   // Handled by sensors alone
  int apiErrorCount   = 0;

  // ── Latest state for UI ───────────────────────────────────────────────
  SensorData?      lastSensors;
  GateResult?      lastGate;
  DetectionResult? lastDetection;
  NavCue?          lastCue;

  CascadeEngine({required TtsService tts}) : _tts = tts;

  /// Main pipeline. Called every frameIntervalMs by NavigationScreen.
  /// Takes current sensor reading + camera frame bytes.
  /// Returns NavCue with what was spoken.
  Future<NavCue> process(SensorData sensors, Uint8List? frameBytes) async {
    final sw = Stopwatch()..start();
    lastSensors = sensors;
    totalFrames++;

    // ── SAFETY LAYER: always first, no AI, no delay ────────────────────
    if (sensors.isCritical) {
      safetyCount++;
      const text = 'Stop! Obstacle directly ahead.';
      await _tts.speakUrgent(text);
      sw.stop();
      final cue = NavCue(
        text:           text,
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

    // ── SENSOR ONLY: not in danger zone, or no frame available ─────────
    if (!sensors.isDanger || frameBytes == null || !AppConfig.isApiKeySet) {
      sensorOnlyCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      // Only speak if something notable
      if (sensors.isCaution) await _tts.speak(cue.text);
      return cue;
    }

    // ── STAGE 1: GATE — is there an obstacle? ──────────────────────────
    gateCalledCount++;
    final gate = await _gemini.runGate(frameBytes);
    lastGate = gate;

    if (!gate.obstacleDetected) {
      // Gate says clear — sensor cue only, no Stage 2 call
      sensorOnlyCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      await _tts.speak(cue.text);

      _checkAndFireSceneDescription(sensors, frameBytes);
      return cue;
    }

    // Gate said YES — proceed to Stage 2
    gateYesCount++;

    // ── STAGE 2: CLASSIFY — what is it exactly? ────────────────────────
    classifyCount++;
    final detection = await _gemini.classify(frameBytes);
    lastDetection   = detection;
    sw.stop();

    if (!detection.success) {
      apiErrorCount++;
      final cue = _buildSensorCue(sensors, sw.elapsedMilliseconds);
      lastCue = cue;
      await _tts.speak(cue.text);
      return cue;
    }

    // Build rich cue: Gemini's own natural-language instruction
    final cue = _buildRichCue(detection, sensors, sw.elapsedMilliseconds);
    lastCue = cue;
    await _tts.speak(cue.text);

    // ── SCENE DESCRIPTION CHECK ──────────────────────────────────────────
    _checkAndFireSceneDescription(sensors, frameBytes);

    return cue;
  }

  /// Checks the 6 smart trigger parameters and fires an async scene
  /// description call if warranted. Never blocks the navigation cue.
  void _checkAndFireSceneDescription(
      SensorData sensors, Uint8List frameBytes) {
    final triggerReason = _sceneDesc.checkTriggers(
      sensors:       sensors,
      lastGate:      lastGate,
      lastDetection: lastDetection,
    );

    if (triggerReason != null) {
      _sceneDesc.describe(frameBytes, triggerReason).then((description) {
        if (description != null && description.isNotEmpty) {
          // Small delay so description doesn't overlap navigation cue
          Future.delayed(const Duration(milliseconds: 900), () {
            _tts.speak(description);
          });
        }
      });
    }
  }

  /// Build rich cue using Gemini's own navigation_instruction —
  /// a complete, natural sentence written for a blind person.
  NavCue _buildRichCue(
      DetectionResult det, SensorData sensors, int latencyMs) {
    String cueText = det.navigationInstruction;

    // If Gemini didn't provide a navigation instruction or it's empty,
    // build one from the structured data
    if (cueText.isEmpty || cueText == 'null') {
      cueText = _buildInstructionFromData(det, sensors);
    }

    // Add urgency prefix for critical situations
    if (det.urgency == 'critical') {
      cueText = 'Warning. $cueText';
    }

    // If ultrasonic says center < 60cm but Gemini didn't mark as critical,
    // override with sensor-informed urgency
    if (sensors.center < 60 && det.urgency != 'critical') {
      cueText = 'Very close. $cueText';
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

  /// Build instruction from structured data when Gemini's
  /// navigation_instruction field is empty.
  String _buildInstructionFromData(DetectionResult det, SensorData sensors) {
    final label     = _labelText(det.label);
    final specifics = det.specifics.isNotEmpty ? det.specifics : label;
    final position  = _positionText(det.position);
    final distance  = det.distanceEstimate;
    final direction = _safeDirectionFromSensors(sensors);

    // Moving person/animal — different instruction
    if (det.isMoving && det.label == ObstacleLabel.person) {
      final moveDir = det.movingDirection;
      if (moveDir == 'toward you') {
        return 'A $specifics is moving toward you from $position, '
               '$distance away. Stop and wait for them to pass.';
      } else if (moveDir == 'crossing left to right') {
        return 'Someone is crossing your path from left to right. '
               'Pause briefly and let them pass.';
      } else if (moveDir == 'crossing right to left') {
        return 'Someone is crossing your path from right to left. '
               'Pause briefly and let them pass.';
      }
    }

    // Stairs — critical, always specific
    if (det.label == ObstacleLabel.stairs_down) {
      return 'Stairs going down are $distance ahead $position. '
             'Slow down and find the handrail.';
    }
    if (det.label == ObstacleLabel.stairs_up) {
      return 'Stairs going up are $distance ahead $position. '
             'Approach carefully.';
    }

    // Door
    if (det.label == ObstacleLabel.door_open) {
      return 'An open door is $position, $distance. You can pass through.';
    }
    if (det.label == ObstacleLabel.door_closed) {
      return 'A closed door is directly $position, $distance. '
             'Reach forward to open it.';
    }

    // Group of people
    if (det.label == ObstacleLabel.group_of_people) {
      return 'A group of people is $distance $position. '
             '$direction to go around them.';
    }

    // Default with rich description
    return 'A $specifics is $distance $position. $direction.';
  }

  /// Build sensor-only cue when AI is not needed or unavailable.
  NavCue _buildSensorCue(SensorData sensors, int latencyMs) {
    String text;
    String direction;

    if (sensors.center < 40) {
      text      = 'Stop immediately. Something is directly in front of you.';
      direction = 'stop';
    } else if (sensors.center < 80) {
      direction = sensors.safeDirection;
      final dist = sensors.center.round();
      text = 'Obstacle about $dist centimetres ahead. $direction.';
    } else if (sensors.left < 60) {
      direction = 'move right';
      text = 'Something very close on your left. Move to your right.';
    } else if (sensors.right < 60) {
      direction = 'move left';
      text = 'Something very close on your right. Move to your left.';
    } else if (sensors.left < 100) {
      direction = 'move slightly right';
      text = 'Object on your left. Drift slightly to your right.';
    } else if (sensors.right < 100) {
      direction = 'move slightly left';
      text = 'Object on your right. Drift slightly to your left.';
    } else {
      direction = 'proceed';
      text      = 'Path is clear. Continue forward.';
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

  String _safeDirectionFromSensors(SensorData sensors) {
    if (sensors.left > sensors.right + 40) return 'Move to your left';
    if (sensors.right > sensors.left + 40) return 'Move to your right';
    if (sensors.center < 80) return 'Stop and wait';
    return 'Proceed with caution';
  }

  String _extractDirection(DetectionResult det) {
    final instruction = det.navigationInstruction.toLowerCase();
    if (instruction.contains('move left') ||
        instruction.contains('step left') ||
        instruction.contains('go left')) return 'left';
    if (instruction.contains('move right') ||
        instruction.contains('step right') ||
        instruction.contains('go right')) return 'right';
    if (instruction.contains('stop') ||
        instruction.contains('wait')) return 'stop';
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

  /// API savings percentage — the main research finding
  double get apiSavingPercent =>
      totalFrames > 0
          ? (1.0 - classifyCount / totalFrames) * 100.0
          : 0.0;

  /// Gate trigger rate
  double get gateTriggerPercent =>
      totalFrames > 0 ? gateYesCount / totalFrames * 100.0 : 0.0;

  SceneDescriptionService get sceneDescService => _sceneDesc;
  String get lastSceneDescription => _sceneDesc.lastDescription;

  Map<String, dynamic> toStats() => {
    'total_frames':         totalFrames,
    'gate_called':          gateCalledCount,
    'gate_yes':             gateYesCount,
    'classify_called':      classifyCount,
    'sensor_only':          sensorOnlyCount,
    'safety_overrides':     safetyCount,
    'api_errors':           apiErrorCount,
    'api_saving_percent':   apiSavingPercent.toStringAsFixed(1),
    'gate_trigger_percent': gateTriggerPercent.toStringAsFixed(1),
  };
}


