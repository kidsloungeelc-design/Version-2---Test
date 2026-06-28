class AppConfig {
  static String geminiApiKey = 'YOUR_GEMINI_API_KEY_HERE';

  static const String geminiEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent';

  // Safety distances (cm)
  static double criticalDistance = 40.0;
  static double dangerDistance   = 100.0;  // increased from 80
  static double cautionDistance  = 180.0;  // increased from 150

  // Pipeline timing — slowed down significantly
  static int frameIntervalMs    = 2500;  // was 500ms — now 2.5 seconds
  static int geminiTimeoutSecs  = 8;     // was 6

  // TTS cooldowns (ms)
  static const int ttsSameCueCooldownMs     = 4000;  // don't repeat same cue within 4s
  static const int ttsAnyCueCooldownMs      = 2000;  // minimum gap between any cues
  static const int ttsSceneDescCooldownMs   = 1200;  // delay before scene desc plays

  // Importance ranking thresholds
  static const int importanceHighMs    = 0;     // speak immediately
  static const int importanceMediumMs  = 500;   // slight delay
  static const int importanceLowMs     = 1200;  // longer delay

  // Arduino serial
  static const int arduinoBaudRate = 9600;

  // Velocity tracking
  static const int velocityHistoryCount   = 5;    // frames to track for velocity
  static const double movingVelocityThreshold = 15.0; // cm/s to count as moving

  // Scene description triggers
  static const double sceneDescProximityThreshold  = 150.0;
  static const double sceneDescAmbiguousLow        = 0.35;
  static const double sceneDescAmbiguousHigh       = 0.65;
  static const int    sceneDescStationarySeconds   = 5;
  static const int    sceneDescPeriodicSeconds     = 25;
  static const int    sceneDescMinGapSeconds       = 5;
  static const int    sceneDescCrowdedMinGap       = 18;
  static const int    sceneDescComplexMinGap       = 30;

  // Complex scene description triggers
  static const double complexSceneMultiObstacleCount = 2;
  static const int    complexSceneNarrowCm           = 80;

  static bool get isApiKeySet =>
      geminiApiKey.isNotEmpty && geminiApiKey != 'YOUR_GEMINI_API_KEY_HERE';
}

