import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/speech_to_text_provider.dart';
import 'screens/app_shell.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SpeechToTextProvider(),
      child: MaterialApp(
        title: 'HearNow',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
          useMaterial3: true,
        ),
        home: const AppShell(),
      ),
    );
  }
}


