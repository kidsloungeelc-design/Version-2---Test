import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image/image.dart' as img;
import 'package:convert/convert.dart';
import '../config.dart';
import '../services/gemini_service.dart';
import '../services/tts_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late TextEditingController _apiKeyController;
  double _criticalDist = AppConfig.criticalDistance;
  double _dangerDist = AppConfig.dangerDistance;
  int _frameInterval = AppConfig.frameIntervalMs;
  String _testResult = '';
  bool _testing = false;
  bool _obscureKey = true;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: AppConfig.geminiApiKey);
    _loadSavedValues();
  }

  Future<void> _loadSavedValues() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _criticalDist = prefs.getDouble('critical_distance') ?? AppConfig.criticalDistance;
      _dangerDist = prefs.getDouble('danger_distance') ?? AppConfig.dangerDistance;
      _frameInterval = prefs.getInt('frame_interval_ms') ?? AppConfig.frameIntervalMs;
      _apiKeyController.text = prefs.getString('gemini_api_key') ?? AppConfig.geminiApiKey;
    });
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    super.dispose();
  }

  Future<void> _testApiKey() async {
    setState(() {
      _testing = true;
      _testResult = 'Testing...';
    });

    try {
      final testKey = _apiKeyController.text.trim();
      if (testKey.isEmpty || testKey == 'YOUR_GEMINI_API_KEY_HERE') {
        setState(() {
          _testResult = 'Please enter a valid API key';
          _testing = false;
        });
        return;
      }

      // Temporarily set the key for testing
      final originalKey = AppConfig.geminiApiKey;
      AppConfig.geminiApiKey = testKey;

      // Create a tiny black 1x1 image for testing
      final image = img.Image(width: 1, height: 1);
      img.fill(image, color: img.ColorRgb8(0, 0, 0));
      final bytes = Uint8List.fromList(img.encodeJpg(image));

      final gemini = GeminiService();
      final result = await gemini.runGate(bytes);

      // Restore original key
      AppConfig.geminiApiKey = originalKey;

      setState(() {
        _testResult = '✓ Valid API key';
        _testing = false;
      });
    } catch (e) {
      setState(() {
        _testResult = '✗ Invalid: ${e.toString().substring(0, 50)}';
        _testing = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.setString('gemini_api_key', _apiKeyController.text.trim());
    await prefs.setDouble('critical_distance', _criticalDist);
    await prefs.setDouble('danger_distance', _dangerDist);
    await prefs.setInt('frame_interval_ms', _frameInterval);

    // Update AppConfig
    AppConfig.geminiApiKey = _apiKeyController.text.trim();
    AppConfig.criticalDistance = _criticalDist;
    AppConfig.dangerDistance = _dangerDist;
    AppConfig.frameIntervalMs = _frameInterval;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved')),
      );
      Navigator.pop(context);
    }
  }

  Future<void> _testTts() async {
    final tts = TtsService();
    await tts.init();
    await tts.speak('Navigation assistant ready');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // API Key section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Gemini API Key',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Get free key at aistudio.google.com',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: _obscureKey,
                    decoration: InputDecoration(
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
                        onPressed: () {
                          setState(() {
                            _obscureKey = !_obscureKey;
                          });
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      ElevatedButton(
                        onPressed: _testing ? null : _testApiKey,
                        child: _testing
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Test Key'),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _testResult,
                          style: TextStyle(
                            color: _testResult.startsWith('✓') ? Colors.green : Colors.red,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Safety Thresholds section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Safety Thresholds',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Critical stop distance: ${_criticalDist.round()}cm',
                    style: const TextStyle(fontSize: 16),
                  ),
                  Slider(
                    value: _criticalDist,
                    min: 20,
                    max: 80,
                    divisions: 6,
                    label: '${_criticalDist.round()}cm',
                    onChanged: (value) {
                      setState(() {
                        _criticalDist = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Danger zone distance: ${_dangerDist.round()}cm',
                    style: const TextStyle(fontSize: 16),
                  ),
                  Slider(
                    value: _dangerDist,
                    min: 60,
                    max: 200,
                    divisions: 14,
                    label: '${_dangerDist.round()}cm',
                    onChanged: (value) {
                      setState(() {
                        _dangerDist = value;
                      });
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // AI Pipeline section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'AI Pipeline',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Frame capture interval',
                    style: TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<int>(
                    value: _frameInterval,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(value: 300, child: Text('300ms')),
                      DropdownMenuItem(value: 500, child: Text('500ms')),
                      DropdownMenuItem(value: 750, child: Text('750ms')),
                      DropdownMenuItem(value: 1000, child: Text('1000ms')),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _frameInterval = value;
                        });
                      }
                    },
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Audio section
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Audio',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _testTts,
                    child: const Text('Test TTS'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Save button
          ElevatedButton(
            onPressed: _saveSettings,
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text(
              'Save Settings',
              style: TextStyle(fontSize: 20),
            ),
          ),
        ],
      ),
    );
  }
}
