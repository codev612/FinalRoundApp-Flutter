import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config/app_config.dart';
import '../providers/speech_to_text_provider.dart';
import '../models/transcript_bubble.dart';

class MeetingPage extends StatefulWidget {
  const MeetingPage({super.key});

  @override
  State<MeetingPage> createState() => _MeetingPageState();
}

class _MeetingPageState extends State<MeetingPage> {
  final ScrollController _transcriptScrollController = ScrollController();
  final TextEditingController _askAiController = TextEditingController();
  final TextEditingController _aiResponseController = TextEditingController();
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
      provider.initialize(
        wsUrl: AppConfig.serverWebSocketUrl,
        httpBaseUrl: AppConfig.serverHttpBaseUrl,
      );
    });
  }

  @override
  void dispose() {
    _transcriptScrollController.dispose();
    _askAiController.dispose();
    _aiResponseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<SpeechToTextProvider>(
      builder: (context, provider, child) {
        _maybeAutoScroll(provider);

        final aiText = provider.aiErrorMessage.isNotEmpty
            ? 'Error: ${provider.aiErrorMessage}'
            : provider.aiResponse;
        if (_aiResponseController.text != aiText) {
          _aiResponseController.text = aiText;
          _aiResponseController.selection = TextSelection.collapsed(
            offset: _aiResponseController.text.length,
          );
        }

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Status indicator + alarm button
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Tooltip(
                    message: provider.isConnected ? 'Connected' : 'Not connected',
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: () {
                        // Intentionally no visible text; tooltip conveys state.
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: provider.isConnected
                              ? Colors.green.shade500
                              : Colors.grey.shade400,
                        ),
                        child: Icon(
                          provider.isConnected ? Icons.check : Icons.close,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.alarm),
                    tooltip: 'Show messages',
                    onPressed: () {
                      final hasError = provider.errorMessage.isNotEmpty;
                      final hasAiError = provider.aiErrorMessage.isNotEmpty;
                      final messageBuffer = StringBuffer();
                      if (hasError) {
                        messageBuffer.writeln('Error: ${provider.errorMessage}');
                      }
                      if (hasAiError) {
                        if (messageBuffer.isNotEmpty) messageBuffer.writeln();
                        messageBuffer.writeln('AI Error: ${provider.aiErrorMessage}');
                      }
                      if (messageBuffer.isEmpty) {
                        messageBuffer.write('No messages to show.');
                      }
                      showDialog(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Messages'),
                          content: Text(messageBuffer.toString()),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
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
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Ask AI + AI Response (separate control)
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _askAiController,
                      enabled: !provider.isAiLoading,
                      decoration: const InputDecoration(
                        labelText: 'Ask AI (optional)',
                        hintText: 'e.g., “What should I ask next?”',
                        border: OutlineInputBorder(),
                        isDense: true,
                      ),
                      textInputAction: TextInputAction.send,
                      onSubmitted: (value) {
                        provider.askAi(question: value);
                      },
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: provider.isAiLoading
                        ? null
                        : () {
                            provider.askAi(question: _askAiController.text);
                          },
                    icon: provider.isAiLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_awesome),
                    label: Text(provider.isAiLoading ? 'Asking…' : 'Ask AI'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _aiResponseController,
                readOnly: true,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: 'AI Response',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),

              // Control buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // Clear button
                  ElevatedButton.icon(
                    onPressed: provider.isRecording ? null : provider.clearTranscript,
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
                      backgroundColor: provider.isRecording ? Colors.red : Colors.blue,
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
    );
  }
}
