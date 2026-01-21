import 'package:flutter/material.dart';

class HomePage extends StatelessWidget {
  final VoidCallback onStartInterview;

  const HomePage({super.key, required this.onStartInterview});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'HearNow',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Interview assistant with separate mic + system transcripts.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: onStartInterview,
            icon: const Icon(Icons.record_voice_over),
            label: const Text('Start Interview'),
          ),
          const SizedBox(height: 12),
          Text(
            'Tip: set server URL via --dart-define.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
