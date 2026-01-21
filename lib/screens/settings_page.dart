import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../config/app_config.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Connection',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        ListTile(
          leading: const Icon(Icons.link),
          title: const Text('WebSocket URL'),
          subtitle: Text(AppConfig.serverWebSocketUrl),
          trailing: IconButton(
            tooltip: 'Copy',
            icon: const Icon(Icons.copy),
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: AppConfig.serverWebSocketUrl),
              );
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Server URL copied')),
              );
            },
          ),
        ),
      ],
    );
  }
}
