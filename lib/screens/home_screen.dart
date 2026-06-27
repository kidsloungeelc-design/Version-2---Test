import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/arduino_service.dart';
import '../services/camera_service.dart';
import '../config.dart';
import 'navigation_screen.dart';
import 'settings_screen.dart';
import 'results_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _cameraReady = false;
  bool _arduinoConnected = false;
  bool _apiKeySet = false;
  List<String> _usbDevices = [];
  final ArduinoService _arduino = ArduinoService();

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    _apiKeySet = AppConfig.isApiKeySet;
    
    final arduinoOk = await _arduino.connect();
    _arduinoConnected = arduinoOk;
    
    _usbDevices = await _arduino.listDevices();
    
    final cameraOk = await CameraService().init();
    _cameraReady = cameraOk;
    
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('NavAssist — AI Navigation'),
        centerTitle: true,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Title section
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'AI Navigation Assistant',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'For visually impaired users',
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey,
                ),
              ),
              SizedBox(height: 24),
            ],
          ),

          // Status checklist card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'System Status',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _statusRow('Camera', _cameraReady, 'Camera not available'),
                  _statusRow('Arduino', _arduinoConnected, 'Check OTG cable'),
                  _statusRow('API Key', _apiKeySet, 'Go to Settings'),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Arduino connection help
          if (!_arduinoConnected)
            Card(
              color: Colors.blue.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'To connect Arduino:',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text('1. Plug OTG adapter into phone'),
                    const Text('2. Connect Arduino to OTG adapter'),
                    const Text('3. Tap Reconnect below'),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _checkStatus,
                      child: const Text('Reconnect'),
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 16),

          // API key warning
          if (!_apiKeySet)
            Card(
              color: Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Gemini API key not configured.',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'App works in sensor-only mode.',
                    ),
                    const Text(
                      'Go to Settings to add your key.',
                    ),
                  ],
                ),
              ),
            ),

          const SizedBox(height: 24),

          // Main buttons
          ElevatedButton(
            onPressed: () {
              Navigator.pushNamed(context, '/nav');
            },
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
              backgroundColor: Theme.of(context).colorScheme.primary,
              foregroundColor: Colors.white,
            ),
            child: const Text(
              'Start Navigation',
              style: TextStyle(fontSize: 20),
            ),
          ),

          const SizedBox(height: 12),

          OutlinedButton(
            onPressed: () {
              Navigator.pushNamed(context, '/settings');
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
            ),
            child: const Text(
              'Settings',
              style: TextStyle(fontSize: 18),
            ),
          ),

          const SizedBox(height: 12),

          OutlinedButton(
            onPressed: () {
              Navigator.pushNamed(context, '/results');
            },
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(60),
            ),
            child: const Text(
              'View Results',
              style: TextStyle(fontSize: 18),
            ),
          ),

          const SizedBox(height: 24),

          // Footer
          Text(
            'USB devices found: ${_usbDevices.join(', ')}',
            style: const TextStyle(
              fontSize: 14,
              color: Colors.grey,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(String label, bool ok, String errorHint) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.cancel,
            color: ok ? Colors.green : Colors.red,
            size: 24,
          ),
          const SizedBox(width: 12),
          Text(
            label,
            style: const TextStyle(fontSize: 18),
          ),
          if (!ok) ...[
            const SizedBox(width: 8),
            Text(
              errorHint,
              style: const TextStyle(
                fontSize: 14,
                color: Colors.red,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
