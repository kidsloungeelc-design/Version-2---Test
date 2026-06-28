import 'dart:io';
import 'dart:typed_data';
import 'package:camera/camera.dart';

class CameraService {
  CameraController? _controller;
  bool _ready = false;
  bool _capturing = false; // guards against overlapping takePicture() calls

  // Diagnostics
  int successCount = 0;
  int errorCount = 0;
  int skippedOverlapCount = 0;
  String? lastError;
  DateTime? lastSuccessTime;

  bool              get isReady    => _ready;
  CameraController? get controller => _controller;

  /// Initialize rear camera at medium resolution.
  Future<bool> init() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        print('[camera] No cameras available on this device.');
        return false;
      }
      final rear = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _controller = CameraController(
        rear,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );
      await _controller!.initialize();
      _ready = true;
      print('[camera] Ready: ${rear.name}');
      return true;
    } catch (e) {
      print('[camera] init() error: $e');
      lastError = e.toString();
      return false;
    }
  }

  /// Capture single JPEG frame as bytes for Gemini API.
  /// Guards against overlapping captures — if a previous capture is
  /// still in flight when this is called again, skip immediately
  /// instead of throwing "Previous capture has not returned yet".
  Future<Uint8List?> captureFrame() async {
    if (!_ready || _controller == null) return null;

    if (_capturing) {
      skippedOverlapCount++;
      print('[camera] Skipped — previous capture still in progress '
          '(overlap #$skippedOverlapCount)');
      return null;
    }

    _capturing = true;
    XFile? file;
    try {
      file = await _controller!.takePicture();
      final bytes = await file.readAsBytes();

      successCount++;
      lastSuccessTime = DateTime.now();
      return bytes;
    } catch (e) {
      errorCount++;
      lastError = e.toString();
      print('[camera] captureFrame() error (#$errorCount): $e');
      return null;
    } finally {
      _capturing = false;
      // Clean up the temp file so storage doesn't fill up over
      // a long session — takePicture() writes a new file every call.
      if (file != null) {
        try {
          final f = File(file.path);
          if (await f.exists()) await f.delete();
        } catch (_) {
          // Non-fatal — ignore cleanup failures.
        }
      }
    }
  }

  Map<String, dynamic> get stats => {
    'success':         successCount,
    'errors':          errorCount,
    'skipped_overlap': skippedOverlapCount,
    'last_error':      lastError ?? '',
  };

  Future<void> dispose() async {
    _ready = false;
    await _controller?.dispose();
    _controller = null;
  }
}
