import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../services/arduino_service.dart';
import '../services/camera_service.dart';
import '../services/tts_service.dart';
import '../services/cascade_engine.dart';
import '../services/data_logger.dart';
import '../models/sensor_data.dart';
import '../models/detection_result.dart';
import '../config.dart';
import '../widgets/sensor_bar.dart';

class NavigationScreen extends StatefulWidget {
  const NavigationScreen({super.key});

  @override
  State<NavigationScreen> createState() => _NavigationScreenState();
}

class _NavigationScreenState extends State<NavigationScreen> {
  late ArduinoService _arduino;
  late CameraService _camera;
  late TtsService _tts;
  late CascadeEngine _cascade;
  late DataLogger _logger;

  SensorData _sensors = SensorData.empty();
  NavCue? _lastCue;
  bool _isRunning = true;
  bool _arduinoConnected = false;
  Timer? _pipelineTimer;

  // ── Camera frame diagnostics ─────────────────────────────────────────
  int _frameCount = 0;
  int _nullFrameCount = 0;
  int _lastFrameBytes = 0;
  DateTime? _lastFrameTime;

  @override
  void initState() {
    super.initState();
    _arduino = ArduinoService();
    _camera = CameraService();
    _tts = TtsService();
    _cascade = CascadeEngine(tts: _tts);
    _logger = DataLogger();

    _initialize();
  }

  Future<void> _initialize() async {
    await _tts.init();
    await _camera.init();

    _arduinoConnected = await _arduino.connect();

    _arduino.sensorStream.listen((reading) {
      if (mounted) {
        setState(() {
          _sensors = reading;
        });
      }
    });

    await _logger.init();

    _pipelineTimer = Timer.periodic(
      Duration(milliseconds: AppConfig.frameIntervalMs),
      _runCycle,
    );

    await WakelockPlus.enable();
    await _tts.speak("Navigation assistant ready", cueKey: 'startup_ready');
  }

  Future<void> _runCycle(Timer t) async {
    if (!_isRunning) return;

    final bytes = await _camera.captureFrame();
    _frameCount++;
    if (bytes == null) {
      _nullFrameCount++;
    } else {
      _lastFrameBytes = bytes.length;
      _lastFrameTime = DateTime.now();
    }
    // Check `adb logcat` or the Action/run console for this line to
    // confirm the camera is actually producing fresh frames.
    // ignore: avoid_print
    print('[camera] frame #$_frameCount: '
        '${bytes == null ? "NULL" : "${bytes.length} bytes"} '
        '(nullCount=$_nullFrameCount, '
        'camErrors=${_camera.errorCount}, '
        'camOverlap=${_camera.skippedOverlapCount})');

    final cue = await _cascade.process(_sensors, bytes);

    _logger.log(
      sensors: _sensors,
      safetyOverride: _sensors.isCritical,
      gateCalled: _cascade.lastGate != null,
      gate: _cascade.lastGate,
      classifyCalled: _cascade.lastDetection != null,
      detection: _cascade.lastDetection,
      cue: cue,
    );

    if (mounted) {
      setState(() {
        _lastCue = cue;
      });
    }
  }

  @override
  void dispose() {
    _isRunning = false;
    _pipelineTimer?.cancel();
    WakelockPlus.disable();
    _camera.dispose();
    _arduino.disconnect();
    _logger.close();
    _tts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final confirmed = await _showExitDialog();
        if (confirmed && mounted) {
          Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Navigating'),
          actions: [
            Icon(
              _arduinoConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
              color: _arduinoConnected ? Colors.green : Colors.red,
            ),
            const SizedBox(width: 16),
          ],
        ),
        body: Column(
          children: [
            // Camera preview (top half)
            Expanded(
              flex: 2,
              child: _camera.isReady
                  ? CameraPreview(_camera.controller!)
                  : Container(
                      color: Colors.grey.shade900,
                      child: const Center(
                        child: Text(
                          'Camera initializing...',
                          style: TextStyle(color: Colors.white, fontSize: 18),
                        ),
                      ),
                    ),
            ),

            // Sensor bars section
            Container(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  const Text(
                    'SENSORS',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      SensorBar(label: 'L', distance: _sensors.left),
                      SensorBar(label: 'C', distance: _sensors.center),
                      SensorBar(label: 'R', distance: _sensors.right),
                    ],
                  ),
                ],
              ),
            ),

            // Last detection card
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _lastCue == null
                      ? const Text(
                          'Waiting for first detection...',
                          style: TextStyle(fontSize: 16),
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _lastCue!.text,
                              style: const TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                _sourceBadge(_lastCue!.source),
                                const SizedBox(width: 8),
                                Text(
                                  '${_lastCue!.totalLatencyMs}ms',
                                  style: const TextStyle(fontSize: 14),
                                ),
                              ],
                            ),
                          ],
                        ),
                ),
              ),
            ),

            // Scene Description Card
            if (_cascade.lastSceneDescription.isNotEmpty)
              Card(
                color: Colors.blueGrey[800],
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Icon(Icons.visibility, color: Colors.lightBlueAccent, size: 16),
                          const SizedBox(width: 6),
                          const Text(
                            'SCENE DESCRIPTION',
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.lightBlueAccent,
                              fontWeight: FontWeight.bold,
                              letterSpacing: 1.2,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _cascade.lastSceneDescription,
                        style: const TextStyle(fontSize: 15, height: 1.4),
                      ),
                    ],
                  ),
                ),
              ),

            // Session stats row
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text('Frames: ${_cascade.totalFrames}'),
                      Text('API: ${_cascade.classifyCount}'),
                      Text('Saved: ${_cascade.apiSavingPercent.toStringAsFixed(0)}%'),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // ── Camera diagnostics row ─────────────────────────
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Text(
                        'Frame: ${_lastFrameBytes}B'
                        '${_lastFrameTime != null ? " @${_lastFrameTime!.second}s" : ""}',
                        style: TextStyle(
                          fontSize: 12,
                          color: _lastFrameBytes > 0 ? Colors.green : Colors.red,
                        ),
                      ),
                      Text(
                        'Cam err: ${_camera.errorCount}  '
                        'overlap: ${_camera.skippedOverlapCount}',
                        style: TextStyle(
                          fontSize: 12,
                          color: (_camera.errorCount + _camera.skippedOverlapCount) > 0
                              ? Colors.orange
                              : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // STOP button
            Container(
              padding: const EdgeInsets.all(16),
              child: ElevatedButton(
                onPressed: () async {
                  _isRunning = false;
                  _pipelineTimer?.cancel();
                  await _tts.speakUrgent("Navigation stopped",
                      cueKey: 'navigation_stopped');
                  if (mounted) {
                    Navigator.pop(context);
                  }
                },
                style: ElevatedButton.styleFrom(
                  minimumSize: const Size.fromHeight(70),
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
                child: const Text(
                  'STOP NAVIGATION',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sourceBadge(CueSource source) {
    Color color;
    String label;
    switch (source) {
      case CueSource.safety:
        color = Colors.red;
        label = 'SAFETY';
        break;
      case CueSource.sensor:
        color = Colors.grey;
        label = 'SENSOR';
        break;
      case CueSource.gate:
        color = Colors.blue;
        label = 'GATE';
        break;
      case CueSource.gemini:
        color = Colors.green;
        label = 'GEMINI';
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Future<bool> _showExitDialog() async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Stop navigation?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('No'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Yes'),
              ),
            ],
          ),
        ) ??
        false;
  }
}
