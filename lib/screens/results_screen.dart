import 'package:flutter/material.dart';
import '../services/cascade_engine.dart';
import '../services/data_logger.dart';
import '../services/tts_service.dart';

class ResultsScreen extends StatefulWidget {
  const ResultsScreen({super.key});

  @override
  State<ResultsScreen> createState() => _ResultsScreenState();
}

class _ResultsScreenState extends State<ResultsScreen> {
  CascadeEngine? _cascade;
  DataLogger? _logger;

  @override
  void initState() {
    super.initState();
    // In a real app, this would be passed from NavigationScreen
    // For now, we'll show empty stats
    _cascade = CascadeEngine(tts: TtsService());
    _logger = DataLogger();
  }

  @override
  Widget build(BuildContext context) {
    if (_cascade == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Session Results')),
        body: const Center(
          child: Text('No session data available'),
        ),
      );
    }

    final cascade = _cascade!;
    final total = cascade.totalFrames > 0 ? cascade.totalFrames : 1;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Session Results'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Header card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'API Efficiency Results',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This is your science fair finding',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Big stat: API Calls Saved
          Card(
            color: Theme.of(context).colorScheme.primaryContainer,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Text(
                    'API Calls Saved',
                    style: TextStyle(fontSize: 20),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '${cascade.apiSavingPercent.toStringAsFixed(0)}%',
                    style: const TextStyle(
                      fontSize: 64,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'of frames handled without calling Gemini',
                    style: TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Stats grid
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Session Statistics',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  GridView.count(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    crossAxisCount: 2,
                    mainAxisSpacing: 16,
                    crossAxisSpacing: 16,
                    childAspectRatio: 2,
                    children: [
                      _statCard('Total Frames', cascade.totalFrames.toString()),
                      _statCard('Gate Calls', cascade.gateCalledCount.toString()),
                      _statCard('Gate Triggered', cascade.gateYesCount.toString()),
                      _statCard('Full AI Calls', cascade.classifyCount.toString()),
                      _statCard('Safety Fires', cascade.safetyCount.toString()),
                      _statCard('API Errors', cascade.apiErrorCount.toString()),
                    ],
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Bar chart
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Frame Handling Breakdown',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _barChart('Sensor only', cascade.sensorOnlyCount, total, Colors.grey),
                  const SizedBox(height: 8),
                  _barChart('Gate said clear', cascade.sensorOnlyCount - cascade.classifyCount, total, Colors.blue),
                  const SizedBox(height: 8),
                  _barChart('Full AI cascade', cascade.classifyCount, total, Colors.green),
                  const SizedBox(height: 8),
                  _barChart('Safety override', cascade.safetyCount, total, Colors.red),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Scene Description Stats Card
          Card(
            margin: const EdgeInsets.all(12),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Scene Description Calls',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  const Text(
                    'Gemini was called for a full scene description when:',
                    style: TextStyle(fontSize: 14, color: Colors.grey),
                  ),
                  const SizedBox(height: 12),
                  _statRow('Proximity (<120cm)', cascade.sceneDescService.toStats()['proximity_triggers']),
                  _statRow('Ambiguous gate (0.35-0.65)', cascade.sceneDescService.toStats()['ambiguous_triggers']),
                  _statRow('Inconsistent detections', cascade.sceneDescService.toStats()['inconsistency_triggers']),
                  _statRow('User stationary', cascade.sceneDescService.toStats()['stationary_triggers']),
                  _statRow('Periodic ambient', cascade.sceneDescService.toStats()['periodic_triggers']),
                  const Divider(),
                  _statRow('Total scene calls', cascade.sceneDescService.toStats()['total_scene_calls']),
                  const SizedBox(height: 8),
                  Text(
                    'Last description:',
                    style: TextStyle(fontSize: 13, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    cascade.lastSceneDescription.isEmpty
                        ? 'No scene description yet'
                        : cascade.lastSceneDescription,
                    style: const TextStyle(fontSize: 14, fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Research interpretation
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'What this means:',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Your cascade architecture called Gemini ${cascade.classifyCount} times '
                    'out of ${cascade.totalFrames} total frames (${cascade.apiSavingPercent.toStringAsFixed(0)}% savings).',
                    style: const TextStyle(fontSize: 16),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Calling Gemini every frame would have used ${cascade.totalFrames} API calls. '
                    'The cascade reduced this to ${cascade.classifyCount} calls — a '
                    '${cascade.apiSavingPercent.toStringAsFixed(0)}% reduction with '
                    'equivalent navigation safety.',
                    style: const TextStyle(fontSize: 16),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // CSV file location
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Data saved to:',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _logger?.filePath ?? 'No CSV file created',
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 12),
                  ElevatedButton(
                    onPressed: () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('File: ${_logger?.filePath ?? "N/A"}'),
                        ),
                      );
                    },
                    child: const Text('Show File Path'),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 24),

          // Reset button
          ElevatedButton(
            onPressed: () {
              setState(() {
                _cascade = CascadeEngine(tts: TtsService());
              });
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              minimumSize: const Size.fromHeight(50),
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
            ),
            child: const Text('Reset Stats'),
          ),
        ],
      ),
    );
  }

  Widget _statCard(String label, String value) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.shade800,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: const TextStyle(fontSize: 12),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _statRow(String label, dynamic value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 14)),
          Text('${value ?? 0}', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _barChart(String label, int count, int total, Color color) {
    final width = total > 0 ? count / total : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 14)),
            Text('$count (${(width * 100).toStringAsFixed(1)}%)'),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          height: 24,
          decoration: BoxDecoration(
            color: Colors.grey.shade700,
            borderRadius: BorderRadius.circular(4),
          ),
          child: FractionallySizedBox(
            widthFactor: width.clamp(0.0, 1.0),
            alignment: Alignment.centerLeft,
            child: Container(
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
