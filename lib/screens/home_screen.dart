import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/speech_to_text_provider.dart';
import '../models/transcript_bubble.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _serverUrlController =
      TextEditingController(text: 'ws://localhost:3000/listen');

  final ScrollController _transcriptScrollController = ScrollController();
  int _lastBubbleCount = 0;
  String _lastTailSignature = '';

  void _maybeAutoScroll(SpeechToTextProvider provider) {
    final bubbleCount = provider.bubbles.length;

    final tail = provider.bubbles.isNotEmpty ? provider.bubbles.last : null;
    final tailSignature = tail == null
      ? ''
      : '${tail.source}:${tail.isDraft}:${tail.text.length}:${tail.timestamp.millisecondsSinceEpoch}';

    final changed = bubbleCount != _lastBubbleCount || tailSignature != _lastTailSignature;
    _lastBubbleCount = bubbleCount;
    _lastTailSignature = tailSignature;

    if (!changed) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_transcriptScrollController.hasClients) return;

      final position = _transcriptScrollController.position;
      final target = position.maxScrollExtent;
      // Jump if layout is still changing, otherwise animate for a nicer feel.
      if ((target - position.pixels).abs() < 4) return;
      _transcriptScrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    });
  }

  Widget _buildBubble({required TranscriptSource source, required String text}) {
    final isMe = source == TranscriptSource.mic;

    final backgroundColor = isMe ? Colors.blue.shade600 : Colors.grey.shade300;
    final textColor = isMe ? Colors.white : Colors.black87;

    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: backgroundColor,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            text,
            style: TextStyle(
              fontSize: 16,
              color: textColor,
              fontStyle: FontStyle.normal,
            ),
          ),
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final provider = context.read<SpeechToTextProvider>();
      provider.initialize(_serverUrlController.text);
    });
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _transcriptScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('HearNow - Speech to Text'),
      ),
      body: Consumer<SpeechToTextProvider>(
        builder: (context, provider, child) {
          _maybeAutoScroll(provider);
          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Server URL input
                TextField(
                  controller: _serverUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.link),
                  ),
                  enabled: !provider.isRecording,
                  onChanged: (value) {
                    if (!provider.isRecording) {
                      provider.initialize(value);
                    }
                  },
                ),
                const SizedBox(height: 16),

                // Status indicator
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: provider.isConnected
                        ? Colors.green.shade100
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        provider.isConnected
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: provider.isConnected
                            ? Colors.green
                            : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        provider.isConnected
                            ? 'Connected'
                            : 'Not connected',
                        style: TextStyle(
                          color: provider.isConnected
                              ? Colors.green.shade900
                              : Colors.grey.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // Error message
                if (provider.errorMessage.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: Colors.red.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.error, color: Colors.red),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            provider.errorMessage,
                            style: TextStyle(color: Colors.red.shade900),
                          ),
                        ),
                      ],
                    ),
                  ),

                // Transcript display
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: Builder(
                      builder: (context) {
                        final bubbles = provider.bubbles;
                        final hasAny = bubbles.isNotEmpty;

                        if (!hasAny) {
                          return const Center(
                            child: Text(
                              'Tap the microphone button to start recording',
                              style: TextStyle(
                                color: Colors.grey,
                                fontSize: 16,
                              ),
                            ),
                          );
                        }

                        return ListView.builder(
                          controller: _transcriptScrollController,
                          itemCount: bubbles.length,
                          itemBuilder: (context, index) {
                            final b = bubbles[index];
                            return _buildBubble(source: b.source, text: b.text);
                          },
                        );
                      },
                    )
                  ),
                ),
                const SizedBox(height: 16),

                // Control buttons
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Clear button
                    ElevatedButton.icon(
                      onPressed: provider.isRecording
                          ? null
                          : provider.clearTranscript,
                      icon: const Icon(Icons.clear),
                      label: const Text('Clear'),
                    ),

                    // Record/Stop button
                    ElevatedButton.icon(
                      onPressed: provider.isRecording
                          ? provider.stopRecording
                          : provider.startRecording,
                      icon: Icon(
                        provider.isRecording ? Icons.stop : Icons.mic,
                      ),
                      label: Text(
                        provider.isRecording ? 'Stop' : 'Record',
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: provider.isRecording
                            ? Colors.red
                            : Colors.blue,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
