import 'package:flutter/material.dart';

import 'home_page.dart';
import 'settings_page.dart';
import 'home_screen.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 1; // default to Interview

  @override
  Widget build(BuildContext context) {
    final title = switch (_index) {
      0 => 'Home',
      1 => 'Interview',
      2 => 'Settings',
      _ => 'HearNow',
    };

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(title),
      ),
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: [
            HomePage(
              onStartInterview: () => setState(() => _index = 1),
            ),
            const InterviewPage(),
            const SettingsPage(),
          ],
        ),
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.home_outlined),
            activeIcon: Icon(Icons.home),
            label: 'Home',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.record_voice_over_outlined),
            activeIcon: Icon(Icons.record_voice_over),
            label: 'Interview',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
