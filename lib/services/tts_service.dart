import 'package:flutter_tts/flutter_tts.dart';
import '../config.dart';

enum TtsPriority { critical, high, medium, low }

class _TtsQueueItem {
  final String      text;
  final TtsPriority priority;
  final String      cueKey;
  _TtsQueueItem(this.text, this.priority, this.cueKey);
}

class TtsService {
  final FlutterTts _tts = FlutterTts();

  bool          _ready           = false;
  bool          _speaking        = false;
  TtsPriority?  _currentPriority;
  String?       _lastCueKey;
  DateTime      _lastSpokeForKey = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime      _lastSpokeAny    = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime      _lastFinished    = DateTime.fromMillisecondsSinceEpoch(0);

  int totalSpoken       = 0;
  int duplicatesSkipped = 0;
  int cooldownSkipped   = 0;
  int urgentSpoken      = 0;
  int interruptedCount  = 0;

  final List<_TtsQueueItem> _queue = [];

  bool         get isSpeaking      => _speaking;
  TtsPriority? get currentPriority => _currentPriority;

  Future<void> init() async {
    await _tts.setLanguage('en-US');
    await _tts.setSpeechRate(0.42);   // slightly slower for clarity
    await _tts.setVolume(1.0);
    await _tts.setPitch(1.0);
    // CRITICAL: must be false so completion handler fires
    await _tts.awaitSpeakCompletion(false);

    _tts.setCompletionHandler(() {
      _speaking        = false;
      _currentPriority = null;
      _lastFinished    = DateTime.now();
      // Small gap between sentences so they don't blur together
      Future.delayed(const Duration(milliseconds: 300), _processQueue);
    });

    _tts.setStartHandler(() {
      _speaking = true;
    });

    _ready = true;
  }

  Future<void> speak(
    String text, {
    TtsPriority priority = TtsPriority.medium,
    String?     cueKey,
  }) async {
    if (!_ready) await init();
    if (text.trim().isEmpty) return;

    final key = cueKey ?? text;
    final now = DateTime.now();

    // Don't interrupt if something of equal or higher priority is playing
    final outranksCurrent = _currentPriority == null ||
        priority.index < _currentPriority!.index;

    // Minimum gap after ANY utterance finishes, scaled by priority
    final msSinceFinished = now.difference(_lastFinished).inMilliseconds;
    final minGapAfterSpeech = _minGapAfterSpeech(priority);
    if (!_speaking && msSinceFinished < minGapAfterSpeech) {
      // Still in cooldown after last utterance
      cooldownSkipped++;
      return;
    }

    // Minimum gap between ANY two cue submissions
    final minGapMs = _minGapForPriority(priority);
    if (now.difference(_lastSpokeAny).inMilliseconds < minGapMs) {
      if (priority != TtsPriority.critical && priority != TtsPriority.high) {
        cooldownSkipped++;
        return;
      }
    }

    // Same cue key recently — skip duplicate
    if (key == _lastCueKey &&
        now.difference(_lastSpokeForKey).inMilliseconds 
            AppConfig.ttsSameCueCooldownMs) {
      duplicatesSkipped++;
      return;
    }

    if (_speaking && !outranksCurrent) {
      // Queue it but drop lower-priority items already waiting
      _queue.removeWhere((item) =>
          item.priority.index >= priority.index &&
          item.priority != TtsPriority.critical);
      _queue.add(_TtsQueueItem(text, priority, key));
      _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));
      return;
    }

    if (_speaking && outranksCurrent) {
      // Higher priority — interrupt current speech
      interruptedCount++;
      _queue.clear();
      await _tts.stop();
      _speaking        = false;
      _currentPriority = null;
    }

    _queue.add(_TtsQueueItem(text, priority, key));
    _queue.sort((a, b) => a.priority.index.compareTo(b.priority.index));

    if (!_speaking) _processQueue();
  }

  int _minGapForPriority(TtsPriority p) {
    switch (p) {
      case TtsPriority.critical: return 0;
      case TtsPriority.high:     return 800;
      case TtsPriority.medium:   return AppConfig.ttsAnyCueCooldownMs;
      case TtsPriority.low:      return AppConfig.ttsAnyCueCooldownMs;
    }
  }

  int _minGapAfterSpeech(TtsPriority p) {
    switch (p) {
      case TtsPriority.critical: return 0;
      case TtsPriority.high:     return 400;
      case TtsPriority.medium:   return 800;
      case TtsPriority.low:      return 1500;
    }
  }

  void _processQueue() async {
    if (_queue.isEmpty || _speaking) return;

    final item       = _queue.removeAt(0);
    _speaking        = true;
    _currentPriority = item.priority;
    _lastCueKey      = item.cueKey;
    _lastSpokeForKey = DateTime.now();
    _lastSpokeAny    = DateTime.now();
    totalSpoken++;

    await _tts.speak(item.text);
  }

  Future<void> speakUrgent(
    String text, {
    String cueKey = 'critical_stop',
  }) async {
    if (!_ready) await init();
    if (text.trim().isEmpty) return;

    // Don't cut off an already-playing critical message
    if (_speaking && _currentPriority == TtsPriority.critical) return;

    _queue.clear();
    urgentSpoken++;
    totalSpoken++;
    await _tts.stop();
    _speaking        = true;
    _currentPriority = TtsPriority.critical;
    _lastCueKey      = cueKey;
    _lastSpokeForKey = DateTime.now();
    _lastSpokeAny    = DateTime.now();
    await _tts.speak(text);
  }

  Future<void> stop() async {
    _queue.clear();
    _speaking        = false;
    _currentPriority = null;
    await _tts.stop();
  }

  void dispose() {
    _queue.clear();
    _tts.stop();
  }

  Map<String, int> get stats => {
    'total_spoken':       totalSpoken,
    'duplicates_skipped': duplicatesSkipped,
    'cooldown_skipped':   cooldownSkipped,
    'urgent_spoken':      urgentSpoken,
    'interrupted':        interruptedCount,
  };
}
